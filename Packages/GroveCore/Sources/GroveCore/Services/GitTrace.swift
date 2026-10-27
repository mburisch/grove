import Foundation

/// Totals of the git runs made on behalf of one operation (a refresh, fetch, pull, …), for the
/// debug log. Set it with `GitTrace.$current.withValue(trace) { … }`; every `GitRunner` run in
/// that task and its child tasks is added to it. Safe to use from any thread.
public final class GitTrace: @unchecked Sendable {
    @TaskLocal public static var current: GitTrace?

    public let id: String
    private let lock = NSLock()
    private var calls = 0
    private var runSeconds: TimeInterval = 0
    private var waitSeconds: TimeInterval = 0
    private var bySubcommand: [String: Int] = [:]

    public init(id: String) {
        self.id = id
    }

    /// Adds a finished run.
    public func add(_ run: GitRunRecord) {
        guard let finished = run.finished else { return }
        lock.withLock {
            calls += 1
            runSeconds += finished.timeIntervalSince(run.started)
            waitSeconds += run.started.timeIntervalSince(run.queued ?? run.started)
            bySubcommand[run.subcommand, default: 0] += 1
        }
    }

    /// Fields for the operation's end event: how many runs, how long they ran and waited for a
    /// slot in total (runs overlap, so these can exceed the wall time), and runs per subcommand.
    public var summary: [String: any Sendable] {
        lock.withLock {
            [
                "gitCalls": calls,
                "gitSeconds": (runSeconds * 1000).rounded() / 1000,
                "gitWaitSeconds": (waitSeconds * 1000).rounded() / 1000,
                "gitCallsBySubcommand": bySubcommand,
            ]
        }
    }
}
