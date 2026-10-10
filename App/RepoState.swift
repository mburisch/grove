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

    /// Runs `operation` after any operation already queued for this repository.
    func enqueue(_ label: String, _ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            queued = nil
            activity = label
            await operation()
            activity = nil
        }
        tail = task
        await task.value
    }
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
