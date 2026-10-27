import AppKit
import GroveCore
import Network
import Observation

/// What the window shows: a selection in the tree (with the inspector), or a full-width page.
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
            if config.gitHubPullRequests != oldValue.gitHubPullRequests { gitHubPullRequestsChanged() }
            if config.debugLog != oldValue.debugLog { setDebugLog(config.debugLog) }
            persist()
        }
    }
    private(set) var repos: [RepoState] = []
    var pane: Pane? {
        didSet { if pane != oldValue { cancelDetailLoads() } }
    }
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
    /// What the shown details were last loaded for after a snapshot, by `detailsKey`, so later
    /// snapshots that change nothing they depend on don't load them again.
    @ObservationIgnored private var detailsLoadedFor: [String: DetailsState] = [:]
    /// Loads of details for the shown pane, cancelled (with their git runs) when it changes.
    @ObservationIgnored private var detailLoads: [UUID: Task<Void, Never>] = [:]
    /// Load of the diff shown in the `.diff` pane, cancelled when another file or pane is shown.
    @ObservationIgnored private var diffLoad: Task<Void, Never>?
    /// The file shown in the `.diff` pane and its diff (nil while it loads).
    private(set) var diffSelection: DiffSelection?
    private(set) var currentDiff: FileDiff?

    @ObservationIgnored private let store = ConfigStore()
    /// Each repo's last snapshot, shown after launch until the first refresh is done.
    @ObservationIgnored private let snapshotStore = SnapshotStore()
    /// Writes snapshots one at a time, so an older one never lands after a newer one.
    @ObservationIgnored private let snapshotWrites = DispatchQueue(label: "grove.snapshots", qos: .utility)
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastScan: Date = .distantPast

    /// Shared by every runner so the cap holds across repos and operations.
    @ObservationIgnored private let gitLimiter: GitLimiter
    /// A separate lane for repos with the large profile, so their slow runs (a status that walks a
    /// huge checkout) never take the slots other repos' quick runs need.
    @ObservationIgnored private let largeRepoLimiter = GitLimiter(limit: GitLimiter.largeRepoLimit, name: "large")
    /// Lets large repos run one heavy command (fetch, merge, repack, …) at a time between them, so
    /// they don't compete for the disk and the large lane's other slot stays free for quick runs.
    @ObservationIgnored private let heavyRunLimiter = GitLimiter(limit: 1, name: "heavy")

    /// Records git runs and repository operations with timings while the Debug log setting is on.
    @ObservationIgnored private(set) var debugLog: DebugLog?
    /// Why the debug log couldn't be started, for Settings.
    private(set) var debugLogError: String?

    init() {
        let config = store.load()
        gitLimiter = GitLimiter(limit: config.maxParallelGitRuns, name: "normal")
        self.config = config
        if config.debugLog { setDebugLog(true) }
    }

    /// Starts a new log file or stops writing the current one.
    private func setDebugLog(_ enabled: Bool) {
        debugLog?.close()
        debugLog = nil
        debugLogError = nil
        if enabled {
            do {
                debugLog = try DebugLog()
            } catch {
                debugLogError = "Could not create the log file: \(error.localizedDescription)"
            }
            let bundle = Bundle.main.infoDictionary
            debugLog?.log("environment", [
                "grove": "\(bundle?["CFBundleShortVersionString"] ?? "?") (\(bundle?["CFBundleVersion"] ?? "?"))",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "cpus": ProcessInfo.processInfo.activeProcessorCount,
                "gitPath": config.gitPath.isEmpty ? GitRunner.defaultGitPath : config.gitPath.expandingTilde,
                "maxParallelGitRuns": config.maxParallelGitRuns,
                "gitHubPullRequests": config.gitHubPullRequests,
                "defaultFetchIntervalMinutes": config.defaultFetchIntervalMinutes,
                "repositories": repos.map(\.path),
            ])
        }
        for repo in repos { repo.debugLog = debugLog }
    }

    /// Deletes all debug logs; while logging is on, a new file is started.
    func clearDebugLogs() {
        let enabled = debugLog != nil
        setDebugLog(false)
        DebugLog.clear()
        if enabled { setDebugLog(true) }
    }

    /// Every git run, for the Git Output page.
    let gitLog = GitLog()
    /// Repo the Git Output page is narrowed to, if any.
    var gitLogRepo: String?

    var git: GitRunner {
        GitRunner(
            gitPath: config.gitPath.isEmpty ? GitRunner.defaultGitPath : config.gitPath.expandingTilde,
            limiter: gitLimiter,
            onRecord: recordRun
        )
    }

    /// Whether `repo` runs in the lanes for large repositories (git runs and batch operations).
    private func isLarge(_ repo: RepoState) -> Bool {
        settings(for: repo).profile == .large
    }

    /// A large repo whose git status isn't optimized yet (see `confirmTuning`), unless dismissed.
    func showsTuningHint(_ repo: RepoState) -> Bool {
        isLarge(repo) && repo.tuning?.isOptimized == false && !repo.tuningHintDismissed
    }

    /// Sends a run to the Git Output page and, once finished, to the debug log.
    private var recordRun: @Sendable (GitRunRecord) -> Void {
        let log = gitLog
        let debugLog = debugLog
        return { run in
            if run.finished != nil { debugLog?.log(run) }
            Task { @MainActor in log.record(run) }
        }
    }

    /// Runs the GitHub CLI for pull request lookups, logged with the git runs. Nil when the
    /// setting is off or `gh` isn't installed; nothing else in Grove runs `gh`.
    var gh: GitRunner? {
        guard config.gitHubPullRequests, let path = GitHubPullRequests.ghPath() else { return nil }
        return GitRunner(gitPath: path, tool: "gh", onRecord: recordRun)
    }

    /// Looks up pull requests for the repo's worktree and local branches (not the primary branch,
    /// whose same-named PRs are almost always from forks). Quietly does nothing without `gh`,
    /// a GitHub remote, or a login; the attempt is visible on the Git Output page.
    func loadPullRequests(_ repo: RepoState) async {
        guard let gh, let snapshot = repo.snapshot, let gitHub = snapshot.gitHub else { return }
        repo.pullRequestsLoaded = true
        var branches = snapshot.worktrees.compactMap(\.branch) + snapshot.branches.map(\.name)
        branches = Array(Set(branches)).filter { $0 != snapshot.primaryBranch }.sorted()
        guard !branches.isEmpty else {
            repo.pullRequests = [:]
            return
        }
        let found = await timed(repo, "pullRequests") {
            try? await GitHubPullRequests.fetch(repo: gitHub, branches: branches, gh: gh, in: repo.url)
        }
        if let prs = found,
           config.gitHubPullRequests {  // Not if it was switched off meanwhile.
            repo.pullRequests = prs
        }
    }

    /// Off: forget all pull requests. On: look them up for every repo now.
    private func gitHubPullRequestsChanged() {
        for repo in repos {
            repo.pullRequests = [:]
            repo.pullRequestsLoaded = false
        }
        guard config.gitHubPullRequests else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for repo in repos { group.addTask { await self.loadPullRequests(repo) } }
            }
        }
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
        var runner = git
        if isLarge(repo) {
            runner.limiter = largeRepoLimiter
            runner.heavyLimiter = heavyRunLimiter
        }
        return GitRepository(url: repo.url, git: runner)
    }

    /// `repo`'s settings with its profile's defaults filled in.
    func settings(for repo: RepoState) -> EffectiveRepoSettings {
        config.effectiveSettings(for: repo.path, detected: repo.detectedProfile)
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
        Task {
            debugLog?.log("launch", ["phase": "start"])
            await rebuildRepoList()
            await refreshAll()
            debugLog?.log("launch", ["phase": "refreshed all"])
        }
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
        let scanStart = Date.now
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
        for repo in added { repo.debugLog = debugLog }
        // Show what was seen last time while the first refresh runs; in a big repo it takes a while.
        let store = snapshotStore
        let addedPaths = added.map(\.path)
        let saved = await Task.detached(priority: .userInitiated) {
            addedPaths.compactMap { path in store.load(for: path).map { (path, $0) } }
        }.value
        for (path, entry) in saved {
            guard let repo = added.first(where: { $0.path == path }), repo.snapshot == nil else { continue }
            repo.snapshot = entry.snapshot
            repo.snapshotSaved = entry.saved
            repo.refreshingWorktrees = Set(entry.snapshot.worktrees.map(\.path))
        }
        repos = newRepos
        debugLog?.log("repositories", ["paths": newRepos.map(\.path), "scanSeconds": lastScan.timeIntervalSince(scanStart)])
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
        let store = snapshotStore
        let path = repo.path
        snapshotWrites.async { store.remove(for: path) }
        await rebuildRepoList()
    }

    // MARK: - Refresh / fetch / pull

    func refresh(_ repo: RepoState) async {
        let requested = Date.now
        await repo.enqueue(repo.snapshot == nil ? "Loading…" : "Refreshing…") { [self] in
            // A fetch, pull or refresh that ran while this one waited already took a newer snapshot.
            if let last = repo.lastRefresh, last > requested {
                debugLog?.log("step", ["repo": repo.path, "step": "refresh skipped (newer snapshot)"])
                return
            }
            await loadStorage(repo)
            await loadSnapshot(repo)
        }
    }

    /// `reusing`: worktrees from the current snapshot that can't have changed since (a pull didn't
    /// move them); they keep that status instead of having it read again.
    private func loadSnapshot(_ repo: RepoState, reusing: [WorktreeInfo] = []) async {
        // The size picks the profile, so read it before the first (possibly expensive) snapshot.
        if repo.storage == nil { await loadStorage(repo) }
        if repo.tuning == nil { await loadTuning(repo) }
        do {
            let cachedComparisons = await repo.comparisons.count
            let started = Date.now
            var options = settings(for: repo).snapshotOptions
            options.reuseWorktrees = Dictionary(reusing.map { ($0.path, $0) }) { first, _ in first }
            // A reused worktree runs no status, so it can't write its index this time.
            options.writeIndexIn = indexWritesDue(repo).subtracting(options.reuseWorktrees.keys)
            if !reusing.isEmpty {
                debugLog?.log("step", ["repo": repo.path, "step": "snapshot reuses worktrees", "worktrees": reusing.map(\.path).sorted()])
            }
            if !options.writeIndexIn.isEmpty {
                debugLog?.log("step", ["repo": repo.path, "step": "status writes index", "worktrees": options.writeIndexIn.sorted()])
            }
            // Rows keep showing the previous snapshot; worktrees not read yet show a spinner.
            defer {
                repo.activityStep = nil
                repo.refreshingWorktrees = []
            }
            let snapshot = try await timed(repo, "snapshot") {
                try await repository(repo).snapshot(options: options, cache: repo.comparisons) { @MainActor progress in
                    repo.activityStep = progress.step
                    repo.refreshingWorktrees = progress.pendingWorktrees
                }
            }
            for path in options.writeIndexIn { repo.indexWrittenAt[path] = started }
            repo.snapshot = snapshot
            repo.snapshotSaved = nil
            saveSnapshot(snapshot, of: repo)
            // When it started: changes made while it ran may be missing from it.
            repo.lastRefresh = started
            repo.snapshotTaken = (repo.operationNumber, .now)
            logShape(repo, snapshot, cachedComparisons: cachedComparisons)
            // After launch, show pull requests without waiting for the first fetch.
            if !repo.pullRequestsLoaded && config.gitHubPullRequests {
                repo.pullRequestsLoaded = true
                Task { await loadPullRequests(repo) }
            }
            // Keep the inspected worktree's details current.
            let inspected: (DiffTarget, String)? = switch pane {
            case .worktree(let path, let wt) where path == repo.path: (.worktree(wt), "details(worktree)")
            case .repo(let path) where path == repo.path: snapshot.mainWorktree.map { (.worktree($0.path), "details(main worktree)") }
            case .branch(let path, let name) where path == repo.path: (.branch(name), "details(branch)")
            case .diff(let request) where request.repo == repo.path: (request.target, "details(diff)")
            default: nil
            }
            guard let inspected else { return }
            let (target, step) = inspected
            guard needsDetails(repo, target, after: snapshot) else {
                debugLog?.log("step", ["repo": repo.path, "step": "\(step) skipped (unchanged)"])
                return
            }
            let load = startDetailLoad { [self] in
                await timed(repo, step) {
                    switch target {
                    case .worktree(let path):
                        // The snapshot just read this status, so details can skip scans it rules out.
                        let status = snapshot.worktrees.first { $0.path == path }?.status
                        await loadDetails(repo, worktreePath: path, knownStatus: status)
                    case .branch(let name):
                        await loadDetails(repo, branch: name)
                    }
                    if case .diff = pane, let selection = diffSelection { await loadDiff(selection, in: repo) }
                }
            }
            await load.value
            // Left for another pane before they loaded: load them in full next time.
            if load.isCancelled { detailsLoadedFor[Self.detailsKey(repo.path, target)] = nil }
        } catch {
            repo.fail(error)
        }
    }

    private func saveSnapshot(_ snapshot: RepoSnapshot, of repo: RepoState) {
        let store = snapshotStore
        let path = repo.path
        snapshotWrites.async { try? store.save(snapshot, for: path) }
    }

    /// Worktrees whose status may write the index in the next snapshot: when the repo opted in
    /// (`RepoSettings.refreshIndexCaches`) and has the file system monitor or untracked cache on,
    /// those not written by Grove within the last hour. That status holds `index.lock` while it
    /// runs, so a git command of the user's that changes the index can fail then (it works on retry).
    private func indexWritesDue(_ repo: RepoState) -> Set<String> {
        guard config.settings(for: repo.path).refreshIndexCaches == true, repo.tuning?.usesIndexCaches == true,
              let worktrees = repo.snapshot?.worktrees else { return [] }
        return Set(worktrees.filter { !$0.isPrunable }.map(\.path).filter { path in
            repo.indexWrittenAt[path].map { Date.now.timeIntervalSince($0) >= 3600 } ?? true
        })
    }

    /// What a worktree's or branch's details depend on in a snapshot.
    struct DetailsState: Hashable {
        var worktree: WorktreeInfo?
        var commit: String?
        var baseRef: String?
        var baseSHA: String?
    }

    private static func detailsKey(_ repoPath: String, _ target: DiffTarget) -> String {
        switch target {
        case .worktree(let path): "worktree\0" + path
        case .branch(let name): "branch\0" + branchKey(repoPath, name)
        }
    }

    /// Whether the details of `target` must be loaded again after `snapshot`: they aren't loaded
    /// yet, or something they show may have changed since they were. Remembers the new state.
    private func needsDetails(_ repo: RepoState, _ target: DiffTarget, after snapshot: RepoSnapshot) -> Bool {
        let key = Self.detailsKey(repo.path, target)
        var state = DetailsState(baseRef: snapshot.baseRef, baseSHA: snapshot.baseSHA)
        let loaded: Bool
        switch target {
        case .worktree(let path):
            loaded = details[path] != nil
            state.worktree = snapshot.worktrees.first { $0.path == path }
            // Further edits to files that are already changed only show in line counts; without
            // those, a changed worktree can't be told apart from an unchanged one.
            if let wt = state.worktree, !wt.status.isClean && !settings(for: repo).lineCounts {
                detailsLoadedFor[key] = nil
                return true
            }
        case .branch(let name):
            loaded = branchDetails[Self.branchKey(repo.path, name)] != nil
            state.commit = snapshot.branches.first { $0.name == name }?.commit.sha
        }
        defer { detailsLoadedFor[key] = state }
        return !loaded || detailsLoadedFor[key] != state
    }

    /// Forgets which details are current, so the next snapshot loads them again.
    func forgetLoadedDetails() {
        detailsLoadedFor.removeAll()
    }

    /// Logs how long `body` took as one step of an operation on `repo`.
    private func timed<T>(_ repo: RepoState, _ step: String, _ body: () async throws -> T) async rethrows -> T {
        let start = Date.now
        defer {
            debugLog?.log("step", ["repo": repo.path, "step": step, "start": debugLog?.offset(start) ?? 0,
                                 "seconds": Date.now.timeIntervalSince(start)])
        }
        return try await body()
    }

    /// Logs the size of what a snapshot found and the settings it ran with.
    private func logShape(_ repo: RepoState, _ snapshot: RepoSnapshot, cachedComparisons: Int) {
        let settings = settings(for: repo)
        var fields: [String: any Sendable] = [
            "repo": repo.path,
            "profile": settings.profile.rawValue,
            "detectedProfile": repo.detectedProfile.rawValue,
            "compareAllBranches": settings.compareAllBranches,
            "lineCounts": settings.lineCounts,
            "fetchScope": "\(settings.fetchScope)",
            "fetchIntervalMinutes": settings.fetchIntervalMinutes,
            "mode": "\(snapshot.mode)",
            "worktrees": snapshot.worktrees.count,
            "prunableWorktrees": snapshot.worktrees.filter(\.isPrunable).count,
            "localBranches": snapshot.branches.count,
            "remoteBranches": snapshot.remoteBranches.count,
            "comparedLocal": snapshot.branches.filter { $0.versusPrimary != nil }.count,
            "comparedRemote": snapshot.remoteBranches.filter { $0.versusPrimary != nil }.count,
            "cachedComparisonsBefore": cachedComparisons,
        ]
        if let storage = repo.storage {
            fields["storageBytes"] = storage.totalBytes
            fields["packs"] = storage.packs
            fields["looseObjects"] = storage.looseObjects
        }
        debugLog?.log("repo", fields)
    }

    /// `knownStatus`: the worktree's status from a snapshot taken just now (see `worktreeDetails`).
    func loadDetails(_ repo: RepoState, worktreePath: String, knownStatus: WorkingTreeStatus? = nil) async {
        let loaded = await repository(repo)
            .worktreeDetails(path: worktreePath, primaryRef: repo.snapshot?.baseRef, knownStatus: knownStatus)
        // A cancelled load's git runs were stopped, so what came back is incomplete.
        guard !Task.isCancelled else { return }
        details[worktreePath] = loaded
    }

    func loadDetails(_ repo: RepoState, branch: String) async {
        let loaded = await repository(repo).branchDetails(name: branch, primaryRef: repo.snapshot?.baseRef)
        guard !Task.isCancelled else { return }
        branchDetails[Self.branchKey(repo.path, branch)] = loaded
        await compareOnDemand(repo, branch: branch)
    }

    /// Runs `body` as a load for the shown pane; it is cancelled when the pane changes.
    @discardableResult
    private func startDetailLoad(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await body()
            detailLoads[id] = nil
        }
        detailLoads[id] = task
        return task
    }

    private func cancelDetailLoads() {
        detailLoads.values.forEach { $0.cancel() }
        detailLoads = [:]
        diffLoad?.cancel()
        diffLoad = nil
    }

    /// Compares a branch the snapshot skipped (see `compareAllBranches`) once it's selected.
    private func compareOnDemand(_ repo: RepoState, branch name: String) async {
        guard let snapshot = repo.snapshot, let baseRef = snapshot.baseRef, let baseSHA = snapshot.baseSHA,
              let branch = snapshot.branches.first(where: { $0.name == name }), branch.versusPrimary == nil else { return }
        let lineCounts = settings(for: repo).lineCounts && branch.worktreePath == nil
        let result = await repository(repo).comparison(of: branch.commit.sha, to: CompareTarget(ref: baseRef, sha: baseSHA),
                                                       diff: lineCounts, cache: repo.comparisons)
        guard let i = repo.snapshot?.branches.firstIndex(where: { $0.name == name && $0.commit == branch.commit }) else { return }
        repo.snapshot?.branches[i].versusPrimary = result.count
        if lineCounts { repo.snapshot?.branches[i].committedDiff = result.diff }
    }

    func loadStorage(_ repo: RepoState) async {
        await timed(repo, "storage") {
            let git = repository(repo)
            async let storage = git.storage()
            async let prefetch = git.prefetchStatus()
            repo.storage = await storage
            repo.prefetch = await prefetch
        }
    }

    static func branchKey(_ repoPath: String, _ branch: String) -> String { repoPath + "\0" + branch }

    /// Selects a worktree, branch or repo (its main checkout) and loads its details.
    func select(_ pane: Pane) {
        self.pane = pane
        switch pane {
        case .worktree(let path, let wt):
            if let repo = repo(at: path) { startDetailLoad { await self.loadDetails(repo, worktreePath: wt) } }
        case .branch(let path, let name):
            // Reveal the row in the tree when selected from elsewhere (the repo inspector).
            collapsed.remove(path)
            branchesExpanded.insert(path)
            if let repo = repo(at: path) { startDetailLoad { await self.loadDetails(repo, branch: name) } }
        case .repo(let path):
            if let repo = repo(at: path), let main = repo.mainWorktree {
                startDetailLoad { await self.loadDetails(repo, worktreePath: main.path) }
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
        startDetailLoad { [self] in
            if diffSections(for: request).isEmpty { await loadDetails(repo, target: request.target) }
            guard !Task.isCancelled, pane == .diff(request) else { return }
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
        diffLoad?.cancel()
        diffLoad = Task { await loadDiff(selection, in: repo) }
    }

    private func loadDiff(_ selection: DiffSelection, in repo: RepoState) async {
        let diff = await repository(repo).fileDiff(selection.file, scope: selection.scope)
        // Ignore a slow load after another file was selected.
        if !Task.isCancelled, diffSelection == selection { currentDiff = diff }
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
                group.addTask(priority: priority(for: repo)) { await self.refresh(repo) }
            }
        }
    }

    /// `background`: a scheduled fetch. In a large repository it skips `gc --auto` (no surprise
    /// repack of gigabytes; Clean Up does that) and prunes deleted remote branches at most daily.
    func fetch(_ repo: RepoState, background: Bool = false) async {
        let lighter = background && isLarge(repo)
        // A user's fetch never waits for a lighter background one in its place.
        await repo.enqueue("Fetching…", coalescing: true, variant: lighter ? "background" : "") { [self] in
            repo.lastFetchAttempt = .now
            var options = settings(for: repo).fetchOptions
            if lighter {
                options.autoGC = false
                options.prune = repo.lastPrune.map { Date.now.timeIntervalSince($0) > 24 * 3600 } ?? true
            }
            do {
                try await repository(repo).fetch(remote: repo.snapshot?.remoteName, options: options)
                repo.lastError = nil
                repo.consecutiveFailures = 0
                if options.prune { repo.lastPrune = .now }
                repo.remoteBranchList = nil
            } catch {
                repo.fail(error)
                repo.consecutiveFailures += 1
            }
            await loadStorage(repo)
            await loadSnapshot(repo)
            if repo.lastError == nil { await loadPullRequests(repo) }
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
        await repo.enqueue("Pulling…", coalescing: true) { [self] in
            guard let snapshot = repo.snapshot else { return }
            let git = repository(repo)
            // The fetch normally took the snapshot just before: decide from it instead of reading
            // every worktree's status again. An older one (a fetch that failed to refresh it, or an
            // operation ran in between) is checked again worktree by worktree.
            let isFresh = repo.snapshotIsCurrent(maxAge: Self.snapshotReuseAge)
            var updated = 0
            var skipped: [String] = []
            // Worktrees the pull left alone; the fetch's snapshot of them is still current.
            var unchanged: [WorktreeInfo] = []
            // A worktree the snapshot would have moved turned out different when read again.
            var changedSinceSnapshot = false
            let worktrees = snapshot.worktrees.filter { !$0.isPrunable }
            for (index, wt) in worktrees.enumerated() {
                repo.activityStep = "fast-forward \(index + 1)/\(worktrees.count)"
                do {
                    let outcome = isFresh ? try await git.fastForward(worktree: wt) : try await git.fastForward(worktree: wt.path)
                    // One the snapshot would have moved had its status read again; if that left it
                    // alone, it changed since the snapshot, so the next snapshot reads it too.
                    let keepsSnapshot = isFresh && wt.outcomeWithoutMerge != nil
                    switch outcome {
                    case .updated: updated += 1
                    case .upToDate:
                        if keepsSnapshot { unchanged.append(wt) } else if isFresh { changedSinceSnapshot = true }
                    case .skipped(let reason):
                        if keepsSnapshot { unchanged.append(wt) } else if isFresh { changedSinceSnapshot = true }
                        if (wt.tracking?.behind ?? 0) > 0 { skipped.append("\(wt.branch ?? "HEAD"): \(reason)") }
                    }
                } catch {
                    if isFresh { changedSinceSnapshot = true }
                    skipped.append("\(wt.branch ?? "HEAD"): \(error.localizedDescription.unescapingUnicode)")
                }
            }
            for branch in snapshot.branches where branch.worktreePath == nil && (branch.tracking?.behind ?? 0) > 0 {
                if case .updated = try? await git.fastForward(branch: branch) { updated += 1 }
            }
            repo.lastMessage = Self.pullSummary(updated: updated, skipped: skipped)
            // When nothing moved and nothing turned out changed, the fetch's snapshot is still
            // current; otherwise only what moved or changed (and the refs) is read again.
            if updated > 0 || changedSinceSnapshot { await loadSnapshot(repo, reusing: unchanged) }
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
            await loadSnapshot(repo, reusing: recentWorktrees(repo).filter { $0.path != worktree.path })
        }
    }

    /// How long after a snapshot is done its worktree status is reused instead of read again.
    private static let snapshotReuseAge: TimeInterval = 60

    /// The current snapshot's worktrees if it is still current (`RepoState.snapshotIsCurrent`), for
    /// reusing those an operation didn't touch; none otherwise, so everything is read again.
    private func recentWorktrees(_ repo: RepoState) -> [WorktreeInfo] {
        guard repo.snapshotIsCurrent(maxAge: Self.snapshotReuseAge) else { return [] }
        return repo.snapshot?.worktrees ?? []
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
            // Only a branch without a worktree moved.
            await loadSnapshot(repo, reusing: recentWorktrees(repo))
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

    /// Asks for confirmation, then deletes a local branch that has no worktree. The confirmation
    /// counts, fresh, the commits that exist only on this branch and would be lost.
    func confirmDeleteBranch(_ repo: RepoState, branch: BranchInfo) async {
        let git = repository(repo)
        let unique: Int
        do {
            unique = try await git.commitsOnlyOn(branch: branch.name)
        } catch {
            repo.fail(error)
            return
        }
        var remote = branch.upstream.flatMap { branch.upstreamGone ? nil : "\n\nThe remote branch \($0) is not deleted." } ?? ""
        if let pr = repo.pullRequests[branch.name] {
            let state = switch pr.state {
            case .merged: "was merged"
            case .closed: "was closed without merging"
            case .open, .draft: "is still open"
            }
            remote += "\n\nPull request #\(pr.number) \(state)."
        }

        let alert = NSAlert()
        alert.messageText = "Delete the branch \(branch.name)?"
        if unique > 0 {
            alert.alertStyle = .critical
            alert.informativeText = "\(unique) commit\(unique == 1 ? "" : "s") exist only on this branch "
                + "(not on any other branch, tag or remote) and will be lost.\(remote)"
            alert.addButton(withTitle: "Delete Branch and Commits")
        } else {
            alert.informativeText = "All of its commits are also on other branches, tags or remotes; nothing is lost.\(remote)"
            alert.addButton(withTitle: "Delete Branch")
        }
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await repo.enqueue("Deleting branch…") { [self] in
            do {
                try await git.deleteBranch(branch.name)
                repo.lastMessage = "Deleted branch \(branch.name)"
            } catch {
                repo.fail(error)
            }
            await loadSnapshot(repo)
            if pane == .branch(repo: repo.path, name: branch.name),
               !(repo.snapshot?.branches.contains { $0.name == branch.name } ?? false) {
                select(.repo(repo.path))
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
        updateSettings(repo) { $0.fetchIntervalMinutes = minutes }
    }

    /// Changes `repo`'s settings, refreshing it when that changes what a snapshot computes.
    func updateSettings(_ repo: RepoState, _ change: (inout RepoSettings) -> Void) {
        let before = settings(for: repo).snapshotOptions
        var custom = config.settings(for: repo.path)
        change(&custom)
        config.repoSettings[repo.path] = custom
        if settings(for: repo).snapshotOptions != before { Task { await refresh(repo) } }
    }

    /// Resets `repo` to the defaults of `profile` (nil = chosen by size).
    func applyDefaults(_ profile: RepoProfile?, to repo: RepoState) {
        updateSettings(repo) { $0.applyDefaults(profile) }
    }

    func setPrefetch(_ enabled: Bool, for repo: RepoState) async {
        await repo.enqueue(enabled ? "Enabling prefetch…" : "Disabling prefetch…") { [self] in
            do {
                try await repository(repo).setPrefetch(enabled: enabled)
            } catch {
                repo.fail(error)
            }
            await loadStorage(repo)
        }
    }

    /// Asks, then runs `git gc` to repack the repository and drop unreachable data.
    func confirmCleanUp(_ repo: RepoState) async {
        await loadStorage(repo)
        let before = repo.storage
        let alert = NSAlert()
        alert.messageText = "Clean up \(repo.name)?"
        var info = "Runs git gc: repacks all objects into one pack and deletes unreachable data older than an hour, "
            + "such as branches deleted on the remote and leftovers from background prefetches."
        if let before {
            info += "\n\nNow: \(Self.describe(before))."
        }
        if repo.prefetch?.isActive == true {
            info += "\n\nBackground prefetch is on and will keep adding data; consider turning it off."
        }
        info += "\n\nThis can take a long time on a large repository. Grove runs nothing else on it meanwhile."
        alert.informativeText = info
        alert.addButton(withTitle: "Clean Up")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await repo.enqueue("Cleaning up…") { [self] in
            do {
                try await repository(repo).cleanUp()
                await loadStorage(repo)
                repo.storageWarningDismissed = false
                if let before, let after = repo.storage {
                    let freed = max(0, before.totalBytes - after.totalBytes)
                    repo.lastMessage = "Cleaned up: freed \(Self.bytes(freed)) (\(Self.bytes(before.totalBytes)) → \(Self.bytes(after.totalBytes)))"
                } else {
                    repo.lastMessage = "Cleaned up"
                }
            } catch {
                repo.fail(error)
            }
        }
    }

    /// Lists the remote branches a snapshot left out; kept until the next fetch.
    func loadRemoteBranches(_ repo: RepoState) async {
        guard repo.remoteBranchList == nil, let remote = repo.snapshot?.remoteName else { return }
        do {
            repo.remoteBranchList = try await timed(repo, "remoteBranches") {
                try await repository(repo).remoteBranches(remote: remote)
            }
        } catch {
            repo.fail(error)
        }
    }

    func loadTuning(_ repo: RepoState) async {
        let tuning = await repository(repo).tuning()
        // Cancelled reads come back as "not set"; keep the previous (or no) tuning instead.
        guard !Task.isCancelled else { return }
        repo.tuning = tuning
    }

    /// Lists what turning the tuning settings to `wanted` (default: the suggested ones) changes,
    /// with current values, then applies it.
    func confirmTuning(_ repo: RepoState, wanted: Set<RepoTuning.Option>? = nil) async {
        let tuning = await repository(repo).tuning()
        repo.tuning = tuning
        let changes = tuning.changes(to: wanted ?? tuning.suggested)
        guard !changes.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Change git settings of \(repo.name)?"
        var lines = changes.map { change in
            let current = tuning.setting(change.option)?.current ?? "not set"
            return "• \(change.turnOn ? "Turn on" : "Turn off") \(change.option.title.lowercased()) "
                + "(\(change.option.key): \(current) → \(change.turnOn))"
        }
        lines.append("")
        lines.append("They go in the repository's config (.git/config), so they apply to all its worktrees and to the git "
                     + "commands you run yourself.")
        let turnedOn = changes.filter(\.turnOn).map(\.option)
        if turnedOn.contains(.fsmonitor) {
            lines.append("")
            lines.append(RepoTuning.Option.fsmonitor.summary)
        }
        if turnedOn.contains(.manyFiles) {
            alert.alertStyle = .warning
            lines.append("")
            lines.append("Many-files index: other git apps and editor plugins with their own git engine (libgit2, JGit), "
                         + "and git older than 2.40, may report a corrupt index or fail to show changes. Turning it off "
                         + "here rewrites the index in the classic format.")
        }
        if turnedOn.contains(where: { $0 != .commitGraph }) {
            lines.append("")
            lines.append("Grove then runs git status once in each worktree to build the caches; that takes about as long "
                         + "as a status does now.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await repo.enqueue("Changing git settings…") { [self] in
            do {
                try await repository(repo).applyTuning(changes)
                let on = changes.filter(\.turnOn).map { $0.option.title.lowercased() }
                let off = changes.filter { !$0.turnOn }.map { $0.option.title.lowercased() }
                repo.lastMessage = [on.isEmpty ? nil : "Turned on " + on.joined(separator: ", "),
                                    off.isEmpty ? nil : "turned off " + off.joined(separator: ", ")]
                    .compactMap { $0 }.joined(separator: "; ")
            } catch {
                repo.fail(error)
            }
            await loadTuning(repo)
            await loadSnapshot(repo)
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func describe(_ storage: RepoStorage) -> String {
        var text = "\(bytes(storage.totalBytes)) in \(storage.packs) pack\(storage.packs == 1 ? "" : "s")"
        if storage.looseObjects > 0 { text += " and \(storage.looseObjects.formatted()) loose objects" }
        return text
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

    /// Timer and network-triggered work runs at `.utility`: its git runs wait behind those of
    /// actions the user started (see `GitLimiter`).
    private func startScheduler() {
        scheduler = Task(priority: .utility) { @MainActor [weak self] in
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
            let minutes = settings(for: repo).fetchIntervalMinutes
            guard minutes > 0, repo.activity == nil else { return false }
            let backoff = min(pow(2, Double(repo.consecutiveFailures)), 16)
            guard let last = repo.lastFetch else { return true }
            return now.timeIntervalSince(last) >= Double(minutes) * 60 * backoff
        }
        await runLimited(due, queuedLabel: "Waiting to fetch") { await self.fetch($0, background: true) }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task(priority: .utility) { @MainActor in
                guard let self else { return }
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if cameOnline { await self.fetchDue() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "grove.network"))
        pathMonitor = monitor
    }

    /// Runs `body` for each repo, a few at a time. Repos waiting their turn show `queuedLabel`.
    /// Large repos take turns in a lane of their own, one at a time, beside up to `limit` others:
    /// a long fetch or pull of a big repo neither waits for nor holds up the small ones, and two
    /// big ones don't compete for the disk.
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
        // The repo on screen goes first.
        let items = items.filter { $0.path == inspectedRepo } + items.filter { $0.path != inspectedRepo }
        let large = items.filter(isLarge)
        let others = items.filter { !isLarge($0) }
        async let largeLane: Void = runLane(large, limit: 1, run)
        await runLane(others, limit: limit, run)
        await largeLane
    }

    /// Runs `run` for each item with at most `limit` in flight.
    private func runLane(_ items: [RepoState], limit: Int, _ run: @escaping @MainActor (RepoState) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<limit {
                guard let next = iterator.next() else { break }
                group.addTask(priority: priority(for: next)) { await run(next) }
            }
            for await _ in group {
                if let next = iterator.next() { group.addTask(priority: priority(for: next)) { await run(next) } }
            }
        }
    }

    /// The repo whose page, worktree, branch or diff is shown.
    private var inspectedRepo: String? {
        switch pane {
        case .repo(let path), .worktree(let path, _), .branch(let path, _): path
        case .diff(let request): request.repo
        default: nil
        }
    }

    /// Raised for the repo on screen, so its git runs go ahead of other repos' in a batch;
    /// nil keeps the caller's priority.
    private func priority(for repo: RepoState) -> TaskPriority? {
        repo.path == inspectedRepo ? .userInitiated : nil
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
