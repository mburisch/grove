import AppKit
import GroveCore
import Network
import Observation

/// What the popover shows: a selection in the tree (with the inspector), or a full-width page.
enum Pane: Hashable {
    case repo(String)
    case worktree(repo: String, path: String)
    /// A local branch that isn't checked out in any worktree.
    case branch(repo: String, name: String)
    case clone
    case settings
    case gitLog
    /// One changed file's diff, opened from a worktree's or branch's file list.
    indirect case diff(DiffRequest)

    var isPage: Bool {
        switch self {
        case .clone, .settings, .gitLog, .diff: true
        default: false
        }
    }
}

/// The diff browser for one worktree or branch: changed files in a sidebar, one file's diff beside it.
struct DiffRequest: Hashable {
    let repo: String
    let target: DiffTarget
    /// The page Back returns to.
    let returnTo: Pane

    var title: String {
        switch target {
        case .worktree(let path): (path as NSString).lastPathComponent
        case .branch(let name): name
        }
    }
}

enum DiffTarget: Hashable {
    /// A worktree folder (including the main checkout).
    case worktree(String)
    /// A local branch without a worktree; files open as read-only copies.
    case branch(String)
}

/// One file in the diff browser and the comparison it belongs to.
struct DiffSelection: Hashable {
    let file: FileChange
    let scope: DiffScope
}

@MainActor @Observable
final class AppModel {
    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            gitLimiter.setLimit(config.maxParallelGitRuns)
            persist()
        }
    }
    private(set) var repos: [RepoState] = []
    var pane: Pane?
    var filter = ""
    private(set) var isOnline = true
    var clone = CloneJob()
    var configError: String?
    /// Repos whose worktrees are collapsed in the tree (expanded by default).
    var collapsed: Set<String> = []
    /// Repos whose local branches (those without a worktree) are listed in the tree (collapsed by default).
    var branchesExpanded: Set<String> = []
    /// A repo or group is being dragged over the tree; enables auto-scrolling at its edges.
    var draggingInTree = false
    /// Worktree details keyed by worktree path, loaded when a worktree is inspected.
    private(set) var details: [String: WorktreeDetails] = [:]
    /// Details of branches without a worktree, keyed by `branchKey`, loaded when a branch is inspected.
    private(set) var branchDetails: [String: WorktreeDetails] = [:]
    /// The file shown in the `.diff` pane and its diff (nil while it loads).
    private(set) var diffSelection: DiffSelection?
    private(set) var currentDiff: FileDiff?

    @ObservationIgnored private let store = ConfigStore()
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastScan: Date = .distantPast

    /// Shared by every runner so the cap holds across repos and operations.
    @ObservationIgnored private let gitLimiter: GitLimiter

    init() {
        let config = store.load()
        gitLimiter = GitLimiter(limit: config.maxParallelGitRuns)
        self.config = config
    }

    /// Every git run, for the Git Output page.
    let gitLog = GitLog()
    /// Repo the Git Output page is narrowed to, if any.
    var gitLogRepo: String?

    var git: GitRunner {
        let log = gitLog
        return GitRunner(
            gitPath: config.gitPath.isEmpty ? GitRunner.defaultGitPath : config.gitPath.expandingTilde,
            limiter: gitLimiter,
            onRecord: { run in Task { @MainActor in log.record(run) } }
        )
    }

    /// Which run the Git Output page selects when it opens.
    enum GitLogFocus {
        case latestAction, latestProblem
        /// A specific run, e.g. the one behind an error banner.
        case run(UUID)
    }
    var gitLogFocus: GitLogFocus?

    /// Opens the Git Output page, narrowed to one repo when given, with its latest action
    /// (fetch, pull, …) selected, or its latest failed run when opened from an error.
    func showGitOutput(for repo: RepoState? = nil, selecting focus: GitLogFocus = .latestAction) {
        gitLogRepo = repo?.path
        gitLogFocus = repo == nil ? nil : focus
        pane = .gitLog
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
            configError = "Could not save settings: \(error.localizedDescription.unescapingUnicode)"
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
        case .repo(let path), .worktree(let path, _), .branch(let path, _):
            if repo(at: path) == nil { pane = nil }
        case .diff(let request):
            if repo(at: request.repo) == nil { pane = nil }
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
            case .branch(let path, let name) where path == repo.path:
                await loadDetails(repo, branch: name)
            case .diff(let request) where request.repo == repo.path:
                await loadDetails(repo, target: request.target)
                if let selection = diffSelection { await loadDiff(selection, in: repo) }
            default: break
            }
        } catch {
            repo.fail(error)
        }
    }

    func loadDetails(_ repo: RepoState, worktreePath: String) async {
        details[worktreePath] = await repository(repo)
            .worktreeDetails(path: worktreePath, primaryRef: repo.snapshot?.baseRef)
    }

    func loadDetails(_ repo: RepoState, branch: String) async {
        branchDetails[Self.branchKey(repo.path, branch)] = await repository(repo)
            .branchDetails(name: branch, primaryRef: repo.snapshot?.baseRef)
    }

    static func branchKey(_ repoPath: String, _ branch: String) -> String { repoPath + "\0" + branch }

    /// Selects a worktree, branch or repo (its main checkout) and loads its details.
    func select(_ pane: Pane) {
        self.pane = pane
        switch pane {
        case .worktree(let path, let wt):
            if let repo = repo(at: path) { Task { await loadDetails(repo, worktreePath: wt) } }
        case .branch(let path, let name):
            // Reveal the row in the tree when selected from elsewhere (the repo inspector).
            collapsed.remove(path)
            branchesExpanded.insert(path)
            if let repo = repo(at: path) { Task { await loadDetails(repo, branch: name) } }
        case .repo(let path):
            if let repo = repo(at: path), let main = repo.mainWorktree {
                Task { await loadDetails(repo, worktreePath: main.path) }
            }
        default: break
        }
    }

    /// Opens the diff browser, showing `selection` or else the first changed file.
    func showDiffs(_ request: DiffRequest, selecting selection: DiffSelection? = nil) {
        guard let repo = repo(at: request.repo) else { return }
        pane = .diff(request)
        diffSelection = nil
        currentDiff = nil
        Task {
            if diffSections(for: request).isEmpty { await loadDetails(repo, target: request.target) }
            guard pane == .diff(request) else { return }
            if let first = selection ?? diffSections(for: request).lazy.compactMap({ section in
                section.files.first.map { DiffSelection(file: $0, scope: section.scope) }
            }).first {
                selectDiffFile(first)
            }
        }
    }

    func selectDiffFile(_ selection: DiffSelection) {
        guard case .diff(let request) = pane, let repo = repo(at: request.repo) else { return }
        diffSelection = selection
        currentDiff = nil
        Task { await loadDiff(selection, in: repo) }
    }

    private func loadDiff(_ selection: DiffSelection, in repo: RepoState) async {
        let diff = await repository(repo).fileDiff(selection.file, scope: selection.scope)
        // Ignore a slow load after another file was selected.
        if diffSelection == selection { currentDiff = diff }
    }

    private func loadDetails(_ repo: RepoState, target: DiffTarget) async {
        switch target {
        case .worktree(let path): await loadDetails(repo, worktreePath: path)
        case .branch(let name): await loadDetails(repo, branch: name)
        }
    }

    struct DiffSection: Identifiable {
        let title: String
        let scope: DiffScope
        let files: [FileChange]
        var id: String { title }
    }

    /// The browser's sidebar, built from the same details as the Inspector's file lists.
    func diffSections(for request: DiffRequest) -> [DiffSection] {
        let primary = repo(at: request.repo)?.snapshot?.baseRef
        switch request.target {
        case .worktree(let path):
            guard let details = details[path] else { return [] }
            var sections = [DiffSection(title: "Uncommitted", scope: .uncommitted(worktree: path), files: details.uncommitted)]
            if let primary {
                sections.append(DiffSection(title: "Changed vs \(primary)", scope: .sinceBase(worktree: path, primaryRef: primary),
                                            files: details.changedSinceBase))
            }
            return sections
        case .branch(let name):
            guard let primary, let details = branchDetails[Self.branchKey(request.repo, name)] else { return [] }
            return [DiffSection(title: "Changed vs \(primary)", scope: .branch(name: name, primaryRef: primary),
                                files: details.changedSinceBase)]
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
                repo.fail(error)
                repo.consecutiveFailures += 1
            }
            await loadSnapshot(repo)
        }
    }

    /// Overwrites local tags that moved on the remote, then fetches again.
    func updateClobberedTags(_ repo: RepoState) async {
        let tags = repo.clobberedTags
        await repo.enqueue("Updating tags…") { [self] in
            do {
                try await repository(repo).updateTags(tags, remote: repo.snapshot?.remoteName)
                repo.lastError = nil
                repo.lastMessage = "Updated \(tags.count == 1 ? "tag" : "tags") "
                    + tags.joined(separator: ", ") + " to the remote's version"
            } catch {
                repo.fail(error)
            }
        }
        await fetch(repo)
    }

    func fetchAll() async {
        await runLimited(repos, queuedLabel: "Waiting to fetch") { await self.fetch($0) }
    }

    /// Fetches the repos in a group (nil = the ungrouped repos).
    func fetch(group: RepoGroup.ID?) async {
        let section = config.sections(for: repos.map(\.path)).first { $0.group?.id == group }
        let members = section?.repos.compactMap { repo(at: $0) } ?? []
        await runLimited(members, queuedLabel: "Waiting to fetch") { await self.fetch($0) }
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
                    skipped.append("\(wt.branch ?? "HEAD"): \(error.localizedDescription.unescapingUnicode)")
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
        await runLimited(repos, queuedLabel: "Waiting to pull") { await self.pull($0) }
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
                repo.fail(error)
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
                repo.fail(error)
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
                repo.fail(error)
            }
            await loadSnapshot(repo)
        }
    }

    /// Creates a worktree for `branch` in `destination`, a new folder the user chose. Never picks a
    /// location itself and never opens anything.
    func createWorktree(_ repo: RepoState, branch: String, at destination: URL) async {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            repo.lastError = "\(destination.path.abbreviatingWithTilde) already exists; choose a new folder for the worktree"
            return
        }
        await repo.enqueue("Creating worktree…") { [self] in
            do {
                try await repository(repo).addWorktree(branch: branch, at: destination)
                repo.lastMessage = "Created worktree \(destination.path.abbreviatingWithTilde)"
                collapsed.remove(repo.path)
                await loadSnapshot(repo)
                if let wt = repo.snapshot?.worktrees.first(where: { $0.branch == branch && !$0.isMain }) {
                    select(.worktree(repo: repo.path, path: wt.path))
                }
                return
            } catch {
                repo.fail(error)
            }
            await loadSnapshot(repo)
        }
    }

    /// Asks for confirmation, then deletes a linked worktree's folder. The branch and its commits stay.
    /// The confirmation reads the status fresh and says if uncommitted or untracked changes would be lost.
    func confirmRemoveWorktree(_ repo: RepoState, worktree: WorktreeInfo) async {
        guard !worktree.isMain, !worktree.isLocked else { return }
        let git = repository(repo)
        let name = worktree.branch ?? "detached @ \(worktree.head.prefix(7))"
        let folder = worktree.path.abbreviatingWithTilde

        let alert = NSAlert()
        alert.messageText = "Remove the worktree for \(name)?"
        let keeps = worktree.branch.map { "The branch \($0) and its commits stay in the repository." }
            ?? "Its detached commit stays in the repository only while something else refers to it."
        var dirty = false
        if worktree.isPrunable || !FileManager.default.fileExists(atPath: worktree.path) {
            alert.informativeText = "The folder \(folder) is already gone. This only removes git's record of it.\n\n\(keeps)"
            alert.addButton(withTitle: "Remove")
        } else {
            let status: WorkingTreeStatus
            do {
                status = try await git.workingTreeStatus(path: worktree.path)
            } catch {
                repo.fail(error)
                return
            }
            dirty = !status.isClean
            if dirty {
                alert.alertStyle = .critical
                alert.informativeText = "This worktree has uncommitted changes: \(Self.describe(status)). "
                    + "They will be lost.\n\nThe folder \(folder) will be deleted. \(keeps)"
                alert.addButton(withTitle: "Discard Changes and Remove")
            } else {
                alert.informativeText = "There are no uncommitted changes.\n\nThe folder \(folder) will be deleted. \(keeps)"
                alert.addButton(withTitle: "Remove")
            }
        }
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let missing = worktree.isPrunable || !FileManager.default.fileExists(atPath: worktree.path)
        await repo.enqueue("Removing worktree…") { [self] in
            do {
                if missing {
                    try await git.pruneWorktrees()
                } else {
                    try await git.removeWorktree(path: worktree.path, discardingChanges: dirty)
                }
                repo.lastMessage = "Removed worktree \(folder)"
            } catch {
                repo.fail(error)
            }
            await loadSnapshot(repo)
            if pane == .worktree(repo: repo.path, path: worktree.path),
               !(repo.snapshot?.worktrees.contains { $0.path == worktree.path } ?? false) {
                // Show the branch it had checked out, now without a worktree.
                if let branch = worktree.branch, repo.snapshot?.branches.contains(where: { $0.name == branch }) == true {
                    select(.branch(repo: repo.path, name: branch))
                } else {
                    select(.repo(repo.path))
                }
            }
        }
    }

    private static func describe(_ status: WorkingTreeStatus) -> String {
        var parts: [String] = []
        if status.conflicted > 0 { parts.append("\(status.conflicted) conflicted") }
        if status.staged > 0 { parts.append("\(status.staged) staged") }
        if status.unstaged > 0 { parts.append("\(status.unstaged) modified") }
        if status.untracked > 0 { parts.append("\(status.untracked) untracked") }
        return parts.joined(separator: ", ")
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
                clone.error = error.localizedDescription.unescapingUnicode
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
                    Task { @MainActor in self.configError = "\(launcher.name): \(error.localizedDescription.unescapingUnicode)" }
                }
            }
        case .command(let template):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", Launcher.expand(template, path: path)]
            process.currentDirectoryURL = url
            do { try process.run() } catch { configError = "\(launcher.name): \(error.localizedDescription.unescapingUnicode)" }
        }
    }

    /// Opens a file as it is on a branch that has no worktree: the branch's version is written to a
    /// read-only copy under Caches/Grove/Branches/<repo>/<branch>/ and that copy is opened.
    func openFile(_ path: String, onBranch branch: String, in repo: RepoState, with launcher: Launcher) async {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let copy = caches.appendingPathComponent("Grove/Branches", isDirectory: true)
            .appendingPathComponent(repo.name, isDirectory: true)
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            .appendingPathComponent(path)
        do {
            try await repository(repo).exportFile(path, at: "refs/heads/\(branch)", to: copy)
            open(copy.path, with: launcher)
        } catch {
            repo.fail(error)
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
        await runLimited(due, queuedLabel: "Waiting to fetch") { await self.fetch($0) }
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
        monitor.start(queue: DispatchQueue(label: "grove.network"))
        pathMonitor = monitor
    }

    /// Runs `body` for each repo with at most `limit` in flight.
    /// Runs `body` for each repo, a few at a time. Repos waiting their turn show `queuedLabel`.
    private func runLimited(
        _ items: [RepoState],
        queuedLabel: String,
        limit: Int = 3,
        _ body: @escaping @MainActor (RepoState) async -> Void
    ) async {
        // Repos already busy keep showing their activity; the operation queues behind it anyway.
        for item in items where item.activity == nil { item.queued = queuedLabel }
        let run: @MainActor (RepoState) async -> Void = { repo in
            await body(repo)
            repo.queued = nil
        }
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<limit {
                guard let next = iterator.next() else { break }
                group.addTask { await run(next) }
            }
            for await _ in group {
                if let next = iterator.next() { group.addTask { await run(next) } }
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
