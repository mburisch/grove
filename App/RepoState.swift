import Foundation
import GroveCore
import Observation

/// UI state for one repository. Operations on a repository are serialized through `enqueue`.
@MainActor @Observable
final class RepoState: Identifiable {
    let path: String
    var snapshot: RepoSnapshot?
    /// What the repository is doing right now, e.g. "Fetching…".
    var activity: String?
    /// Part of a batch (Fetch All, Pull All, a group fetch) but not started yet, e.g. "Waiting to fetch".
    var queued: String?
    var lastError: String? {
        didSet { if lastError == nil { clobberedTags = []; lastErrorRun = nil } }
    }
    /// Tags the last fetch refused to update because they moved on the remote; offered as a fix.
    var clobberedTags: [String] = []
    /// The git run behind `lastError`, shown by the banner's Show Output.
    var lastErrorRun: UUID?

    /// Shows `error` as this repo's error, remembering which git run caused it.
    func fail(_ error: Error) {
        let gitError = error as? GitError
        lastError = error.localizedDescription.unescapingUnicode
        lastErrorRun = gitError?.runID
        clobberedTags = gitError?.clobberedTags ?? []
    }
    /// Short result of the last user action, e.g. "Pulled 3 commits".
    var lastMessage: String?
    var lastFetchAttempt: Date?
    var consecutiveFailures = 0
    var lastRefresh: Date?
    /// GitHub pull requests by branch name, from `gh`; updated after each fetch.
    var pullRequests: [String: PullRequestInfo] = [:]
    /// Whether pull requests were looked up at least once (first load happens without a fetch).
    var pullRequestsLoaded = false

    /// Object storage size, read before the first snapshot and after fetches and clean-ups.
    var storage: RepoStorage?
    var prefetch: PrefetchStatus?
    /// Git settings for big checkouts and whether they're on; read when the settings are shown.
    var tuning: RepoTuning?
    /// Remote branches read on demand when snapshots skip them (large repositories); nil until
    /// shown, and again after each fetch.
    var remoteBranchList: [RemoteBranchInfo]?
    /// Last fetch that pruned deleted remote branches; background fetches of large repositories
    /// prune at most daily.
    var lastPrune: Date?
    /// The user dismissed the clean-up suggestion (until the app restarts or the repo is cleaned up).
    var storageWarningDismissed = false

    /// Many packs or loose objects: suggest a clean-up on the repo page and in the list.
    var showsStorageWarning: Bool { storage?.needsCleanUp == true && !storageWarningDismissed }
    /// Comparisons with the primary branch by commit, reused while neither side moves.
    @ObservationIgnored let comparisons = ComparisonCache()

    /// The profile the repository's size suggests.
    var detectedProfile: RepoProfile {
        storage.map { RepoProfile.detect(storageBytes: $0.totalBytes) } ?? .normal
    }

    @ObservationIgnored private var tail: Task<Void, Never>?

    init(path: String) {
        self.path = path
    }

    nonisolated var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var displayPath: String { path.abbreviatingWithTilde }

    var mainWorktree: WorktreeInfo? { snapshot?.mainWorktree }

    /// Ahead/behind of the main checkout against `origin/<primary>`.
    var primaryStatus: AheadBehind? { mainWorktree?.versusPrimary }

    /// Behind count used for the menu bar badge: how far the main checkout trails its upstream.
    var behindCount: Int {
        mainWorktree?.tracking?.behind ?? mainWorktree?.versusPrimary?.behind ?? 0
    }

    var lastFetch: Date? {
        [snapshot?.lastFetchDate, lastFetchAttempt].compactMap { $0 }.max()
    }

    /// Records when operations are queued, start and end (while `activity` shows them).
    @ObservationIgnored var debugLog: DebugLog?

    /// Operations queued with `coalescing` that haven't started yet, by label.
    @ObservationIgnored private var waiting: [String: Task<Void, Never>] = [:]

    /// Runs `operation` after any operation already queued for this repository. With `coalescing`,
    /// an operation with the same label that is queued but not started yet stands in for this one:
    /// it starts later than this request, so it does everything this one would.
    func enqueue(_ label: String, coalescing: Bool = false, _ operation: @escaping @MainActor () async -> Void) async {
        if coalescing, let pending = waiting[label] {
            debugLog?.log("operation", ["repo": path, "label": label, "phase": "coalesced"])
            await pending.value
            return
        }
        let previous = tail
        let id = String(UUID().uuidString.prefix(8))
        debugLog?.log("operation", ["repo": path, "label": label, "id": id, "phase": "queued"])
        let task = Task { @MainActor in
            await previous?.value
            if coalescing { waiting[label] = nil }
            queued = nil
            activity = label
            let start = Date.now
            debugLog?.log("operation", ["repo": path, "label": label, "id": id, "phase": "start"])
            let trace = GitTrace(id: id)
            await GitTrace.$current.withValue(trace) { await operation() }
            activity = nil
            var fields = trace.summary
            fields.merge(["repo": path, "label": label, "id": id, "phase": "end",
                          "wallSeconds": (Date.now.timeIntervalSince(start) * 1000).rounded() / 1000]) { $1 }
            debugLog?.log("operation", fields)
        }
        if coalescing { waiting[label] = task }
        tail = task
        await task.value
    }
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
