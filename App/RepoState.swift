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
    var lastError: String?
    /// Short result of the last user action, e.g. "Pulled 3 commits".
    var lastMessage: String?
    var lastFetchAttempt: Date?
    var consecutiveFailures = 0
    var lastRefresh: Date?

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
