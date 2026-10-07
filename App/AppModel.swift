import AppKit
import GitItCore
import Network
import Observation

/// What the popover shows: a selection in the tree (with the inspector), or a full-width page.
enum Pane: Hashable {
    case repo(String)
    case worktree(repo: String, path: String)
    case clone
    case settings

    var isPage: Bool { self == .clone || self == .settings }
}

@MainActor @Observable
final class AppModel {
    var config: AppConfig {
        didSet { if config != oldValue { persist() } }
    }
    private(set) var repos: [RepoState] = []
    var pane: Pane?
    var filter = ""
    private(set) var isOnline = true
    var clone = CloneJob()
    var configError: String?
    /// Repos whose worktrees are collapsed in the tree (expanded by default).
    var collapsed: Set<String> = []
    /// Worktree details keyed by worktree path, loaded when a worktree is inspected.
    private(set) var details: [String: WorktreeDetails] = [:]

    @ObservationIgnored private let store = ConfigStore()
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastScan: Date = .distantPast

    init() {
        config = store.load()
    }

    var git: GitRunner {
        GitRunner(gitPath: config.gitPath.isEmpty ? GitRunner.defaultGitPath : config.gitPath.expandingTilde)
    }

    func repository(_ repo: RepoState) -> GitRepository {
        GitRepository(url: repo.url, git: git)
    }

    func repo(at path: String) -> RepoState? {
        repos.first { $0.path == path }
    }

    var filteredRepos: [RepoState] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return repos }
        return repos.filter {
            $0.name.lowercased().contains(query)
                || $0.path.lowercased().contains(query)
                || ($0.snapshot?.gitHub?.slug.lowercased().contains(query) ?? false)
        }
    }

    /// List sections (groups, then ungrouped) with the repos matching the filter.
    /// While filtering, sections without matches are hidden.
    var repoSections: [(group: RepoGroup?, repos: [RepoState])] {
        let visible = Dictionary(filteredRepos.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        return config.sections(for: repos.map(\.path)).compactMap { section in
            let members = section.repos.compactMap { visible[$0] }
            if filtering && members.isEmpty { return nil }
            return (section.group, members)
        }
    }

    /// Group being renamed inline in the list.
    var renamingGroup: RepoGroup.ID?

    // MARK: - Groups

    @discardableResult
    func addGroup(named name: String = "New Group", with repo: RepoState? = nil) -> RepoGroup.ID {
        let group = RepoGroup(name: name)
        config.groups.append(group)
        if let repo { moveRepo(repo.path, to: group.id) }
        renamingGroup = group.id
        return group.id
    }

    func renameGroup(_ id: RepoGroup.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let i = config.groups.firstIndex(where: { $0.id == id }) {
            config.groups[i].name = trimmed
        }
        if renamingGroup == id { renamingGroup = nil }
    }

    func deleteGroup(_ id: RepoGroup.ID) {
        config.deleteGroup(id)
    }

    func toggleGroup(_ id: RepoGroup.ID) {
        if let i = config.groups.firstIndex(where: { $0.id == id }) { config.groups[i].collapsed.toggle() }
    }

    func moveRepo(_ path: String, to group: RepoGroup.ID?, before: String? = nil) {
        config.move(repo: path, to: group, before: before, allPaths: repos.map(\.path))
    }

    func moveGroup(_ id: RepoGroup.ID, before: RepoGroup.ID?) {
        config.move(group: id, before: before)
    }

    /// Repos needing attention, for the menu bar badge.
    var behindTotal: Int { repos.filter { $0.behindCount > 0 }.count }
    var hasErrors: Bool { repos.contains { $0.lastError != nil } }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Task { await rebuildRepoList(); await refreshAll() }
        startScheduler()
        startNetworkMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Give the network a moment to come back before catching up.
                try? await Task.sleep(for: .seconds(10))
                await self?.fetchDue()
            }
        }
    }

    private func persist() {
        do {
            try store.save(config)
            configError = nil
        } catch {
            configError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Repository list

    /// Explicit repositories plus everything found under the scan roots, minus exclusions.
    func rebuildRepoList() async {
        let roots = config.scanRoots
        let scanned = await Task.detached(priority: .utility) {
            roots.flatMap { RepoScanner.scan(root: URL(fileURLWithPath: $0.path.expandingTilde), maxDepth: $0.depth) }
                .map(\.path)
        }.value
        lastScan = .now

        let excluded = Set(config.excluded)
        var seen = Set<String>()
        let paths = (config.repositories + scanned).filter { path in
            !excluded.contains(path) && seen.insert(path).inserted
                && FileManager.default.fileExists(atPath: path)
        }
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.path, $0) })
        let newRepos = paths.map { existing[$0] ?? RepoState(path: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let added = newRepos.filter { existing[$0.path] == nil }
        repos = newRepos
        switch pane {
        case .repo(let path), .worktree(let path, _):
            if repo(at: path) == nil { pane = nil }
        default: break
        }
        for repo in added { Task { await refresh(repo) } }
    }

    func addRepositories(_ urls: [URL]) async {
        var invalid: [String] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard GitRepository.isRepository(url) else { invalid.append(url.lastPathComponent); continue }
            config.excluded.removeAll { $0 == path }
            if !config.repositories.contains(path) { config.repositories.append(path) }
        }
        await rebuildRepoList()
        if let last = urls.last, let repo = repo(at: last.standardizedFileURL.path) { select(.repo(repo.path)) }
        if !invalid.isEmpty { configError = "Not a git repository: \(invalid.joined(separator: ", "))" }
    }

    /// Removes a repository from the list (never deletes files). Scanned repos are remembered as excluded.
    func remove(_ repo: RepoState) async {
        config.repositories.removeAll { $0 == repo.path }
        let isScanned = config.scanRoots.contains { repo.path.hasPrefix($0.path.expandingTilde + "/") }
        if isScanned, !config.excluded.contains(repo.path) { config.excluded.append(repo.path) }
        config.repoSettings[repo.path] = nil
        config.forgetOrdering(of: repo.path)
        await rebuildRepoList()
    }

    // MARK: - Refresh / fetch / pull

    func refresh(_ repo: RepoState) async {
        await repo.enqueue(repo.snapshot == nil ? "Loading…" : "Refreshing…") { [self] in
            await loadSnapshot(repo)
        }
    }

    private func loadSnapshot(_ repo: RepoState) async {
        do {
            let snapshot = try await repository(repo).snapshot()
            repo.snapshot = snapshot
            repo.lastRefresh = .now
            // Keep the inspected worktree's details current.
            switch pane {
            case .worktree(let path, let wt) where path == repo.path:
                await loadDetails(repo, worktreePath: wt)
            case .repo(let path) where path == repo.path:
                if let main = snapshot.mainWorktree { await loadDetails(repo, worktreePath: main.path) }
            default: break
            }
        } catch {
            repo.lastError = error.localizedDescription
        }
    }

    func loadDetails(_ repo: RepoState, worktreePath: String) async {
        details[worktreePath] = await repository(repo)
            .worktreeDetails(path: worktreePath, primaryRef: repo.snapshot?.baseRef)
    }

    /// Selects a worktree (or a repo's main checkout) and loads its details.
    func select(_ pane: Pane) {
        self.pane = pane
        switch pane {
        case .worktree(let path, let wt):
            if let repo = repo(at: path) { Task { await loadDetails(repo, worktreePath: wt) } }
        case .repo(let path):
            if let repo = repo(at: path), let main = repo.mainWorktree {
                Task { await loadDetails(repo, worktreePath: main.path) }
            }
        default: break
        }
    }

    func refreshAll(ifOlderThan age: TimeInterval = 0) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos where repo.activity == nil {
                if let last = repo.lastRefresh, Date.now.timeIntervalSince(last) < age { continue }
                group.addTask { await self.refresh(repo) }
            }
        }
    }

    func fetch(_ repo: RepoState) async {
        await repo.enqueue("Fetching…") { [self] in
            repo.lastFetchAttempt = .now
            do {
                try await repository(repo).fetch(remote: repo.snapshot?.remoteName)
                repo.lastError = nil
                repo.consecutiveFailures = 0
            } catch {
                repo.lastError = error.localizedDescription
                repo.consecutiveFailures += 1
            }
            await loadSnapshot(repo)
        }
    }

    func fetchAll() async {
        await runLimited(repos) { await self.fetch($0) }
    }

    /// Fetches the repos in a group (nil = the ungrouped repos).
    func fetch(group: RepoGroup.ID?) async {
        let section = config.sections(for: repos.map(\.path)).first { $0.group?.id == group }
        let members = section?.repos.compactMap { repo(at: $0) } ?? []
        await runLimited(members) { await self.fetch($0) }
    }

    /// Fetches, then fast-forwards every clean worktree and every local branch that is strictly behind.
    func pull(_ repo: RepoState) async {
        await fetch(repo)
        guard repo.lastError == nil else { return }
        await repo.enqueue("Pulling…") { [self] in
            guard let snapshot = repo.snapshot else { return }
            let git = repository(repo)
            var updated = 0
            var skipped: [String] = []
            for wt in snapshot.worktrees where !wt.isPrunable {
                do {
                    switch try await git.fastForward(worktree: wt.path) {
                    case .updated: updated += 1
                    case .upToDate: break
                    case .skipped(let reason):
                        if (wt.tracking?.behind ?? 0) > 0 { skipped.append("\(wt.branch ?? "HEAD"): \(reason)") }
                    }
                } catch {
                    skipped.append("\(wt.branch ?? "HEAD"): \(error.localizedDescription)")
                }
            }
            for branch in snapshot.branches where branch.worktreePath == nil && (branch.tracking?.behind ?? 0) > 0 {
                if case .updated = try? await git.fastForward(branch: branch) { updated += 1 }
            }
            repo.lastMessage = Self.pullSummary(updated: updated, skipped: skipped)
            await loadSnapshot(repo)
        }
    }

    func pullAll() async {
        await runLimited(repos) { await self.pull($0) }
    }

    func pull(_ repo: RepoState, worktree: WorktreeInfo) async {
        await repo.enqueue("Pulling…") { [self] in
            do {
                let outcome = try await repository(repo).fastForward(worktree: worktree.path)
                repo.lastMessage = switch outcome {
                case .updated(let n): "\(worktree.branch ?? "HEAD"): fast-forwarded \(n) commit\(n == 1 ? "" : "s")"
                case .upToDate: "\(worktree.branch ?? "HEAD") is up to date"
                case .skipped(let reason): "\(worktree.branch ?? "HEAD") not updated: \(reason)"
                }
            } catch {
                repo.lastError = error.localizedDescription
            }
            await loadSnapshot(repo)
        }
    }

    func fastForward(_ repo: RepoState, branch: BranchInfo) async {
        await repo.enqueue("Updating \(branch.name)…") { [self] in
            do {
                if case .skipped(let reason) = try await repository(repo).fastForward(branch: branch) {
                    repo.lastMessage = "\(branch.name) not updated: \(reason)"
                }
            } catch {
                repo.lastError = error.localizedDescription
            }
            await loadSnapshot(repo)
        }
    }

    private static func pullSummary(updated: Int, skipped: [String]) -> String {
        var parts: [String] = []
        parts.append(updated == 0 ? "Everything up to date" : "Fast-forwarded \(updated) branch\(updated == 1 ? "" : "es")")
        if !skipped.isEmpty { parts.append("skipped " + skipped.joined(separator: "; ")) }
        return parts.joined(separator: " — ")
    }

    // MARK: - Mode conversion & worktrees

    func convert(_ repo: RepoState, to mode: CheckoutMode) async {
        let depth = config.settings(for: repo.path).shallowDepth ?? 1
        await repo.enqueue("Converting to \(mode.label.lowercased())…") { [self] in
            do {
                try await repository(repo).convert(to: mode, depth: depth)
                repo.lastError = nil
                repo.lastMessage = "Converted to \(mode.label.lowercased()) checkout"
            } catch {
                repo.lastError = error.localizedDescription
            }
            await loadSnapshot(repo)
        }
    }

    /// Creates a worktree next to the repository (`<repo>-<branch>`) and opens it.
    func createWorktree(_ repo: RepoState, branch: String, openWith launcher: Launcher?) async {
        let base = repo.url.deletingLastPathComponent()
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        var target = base.appendingPathComponent("\(repo.name)-\(slug)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = base.appendingPathComponent("\(repo.name)-\(slug)-\(n)")
            n += 1
        }
        let destination = target
        await repo.enqueue("Creating worktree…") { [self] in
            do {
                try await repository(repo).addWorktree(branch: branch, at: destination)
                repo.lastMessage = "Created worktree \(destination.path.abbreviatingWithTilde)"
                collapsed.remove(repo.path)
                if let launcher { open(destination.path, with: launcher) }
                await loadSnapshot(repo)
                if let wt = repo.snapshot?.worktrees.first(where: { $0.branch == branch && !$0.isMain }) {
                    select(.worktree(repo: repo.path, path: wt.path))
                }
                return
            } catch {
                repo.lastError = error.localizedDescription
            }
            await loadSnapshot(repo)
        }
    }

    func setFetchInterval(_ minutes: Int?, for repo: RepoState) {
        var settings = config.settings(for: repo.path)
        settings.fetchIntervalMinutes = minutes
        config.repoSettings[repo.path] = settings
    }

    // MARK: - Clone

    func startClone() {
        guard let source = clone.source else { return }
        let destination = clone.destination
        let mode = clone.mode
        let depth = clone.depth
        let git = git
        clone.isRunning = true
        clone.error = nil
        clone.progress = nil
        clone.task = Task { @MainActor in
            defer { clone.isRunning = false; clone.task = nil }
            do {
                try await GitRepository.clone(source.url, to: destination, mode: mode, depth: depth, git: git) { progress in
                    Task { @MainActor in self.clone.progress = progress }
                }
                if mode == .shallow {
                    config.repoSettings[destination.path] = RepoSettings(shallowDepth: depth)
                }
                clone.reset()
                await addRepositories([destination])
            } catch is CancellationError {
                clone.error = "Clone cancelled"
            } catch {
                clone.error = error.localizedDescription
            }
        }
    }

    // MARK: - Launchers

    var availableLaunchers: [Launcher] {
        config.launchers.filter { launcher in
            guard launcher.enabled else { return false }
            if case .app(let bundleID) = launcher.kind {
                return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            }
            return true
        }
    }

    /// Launchers that can open a single file. Terminals are excluded (Terminal "opening" a script
    /// runs it) and so is Finder (files get "Reveal in Finder" instead).
    var fileLaunchers: [Launcher] {
        availableLaunchers.filter { launcher in
            if case .app(let bundleID) = launcher.kind { return !Self.nonEditorBundleIDs.contains(bundleID) }
            return true
        }
    }

    private static let nonEditorBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.apple.finder",
    ]

    func open(_ path: String, with launcher: Launcher) {
        let url = URL(fileURLWithPath: path)
        switch launcher.kind {
        case .app(let bundleID):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                configError = "\(launcher.name) is not installed"
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    Task { @MainActor in self.configError = "\(launcher.name): \(error.localizedDescription)" }
                }
            }
        case .command(let template):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", Launcher.expand(template, path: path)]
            process.currentDirectoryURL = url
            do { try process.run() } catch { configError = "\(launcher.name): \(error.localizedDescription)" }
        }
    }

    // MARK: - Scheduler

    private func startScheduler() {
        scheduler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if Date.now.timeIntervalSince(lastScan) > 600 { await rebuildRepoList() }
                await fetchDue()
            }
        }
    }

    /// Fetches repositories whose interval has elapsed, backing off after failures.
    func fetchDue() async {
        guard isOnline else { return }
        if config.pauseFetchInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        let now = Date.now
        let due = repos.filter { repo in
            let minutes = config.fetchInterval(for: repo.path)
            guard minutes > 0, repo.activity == nil else { return false }
            let backoff = min(pow(2, Double(repo.consecutiveFailures)), 16)
            guard let last = repo.lastFetch else { return true }
            return now.timeIntervalSince(last) >= Double(minutes) * 60 * backoff
        }
        await runLimited(due) { await self.fetch($0) }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if cameOnline { await self.fetchDue() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "gitit.network"))
        pathMonitor = monitor
    }

    /// Runs `body` for each repo with at most `limit` in flight.
    private func runLimited(_ items: [RepoState], limit: Int = 3, _ body: @escaping @MainActor (RepoState) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<limit {
                guard let next = iterator.next() else { break }
                group.addTask { await body(next) }
            }
            for await _ in group {
                if let next = iterator.next() { group.addTask { await body(next) } }
            }
        }
    }
}

/// State of the clone form.
@MainActor @Observable
final class CloneJob {
    var input = ""
    var folderName = ""
    var destinationRoot = ""
    var mode: CheckoutMode = .full
    var depth = 1
    var isRunning = false
    var progress: GitParsers.Progress?
    var error: String?
    @ObservationIgnored var task: Task<Void, Never>?

    var source: CloneSource? { CloneSource(input: input) }

    var destination: URL {
        let name = folderName.isEmpty ? (source?.suggestedName ?? "") : folderName
        return URL(fileURLWithPath: destinationRoot.expandingTilde).appendingPathComponent(name)
    }

    var destinationExists: Bool { FileManager.default.fileExists(atPath: destination.path) }

    func reset() {
        input = ""
        folderName = ""
        progress = nil
        error = nil
    }
}
