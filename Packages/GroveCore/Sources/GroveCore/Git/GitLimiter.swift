import Foundation

/// Caps how many git processes run at once. Callers beyond the limit wait in FIFO order;
/// a waiting caller that is cancelled leaves the queue and throws `CancellationError`.
public final class GitLimiter: @unchecked Sendable {
    public static let defaultLimit = 4

    private let lock = NSLock()
    private var limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Waiters cancelled before their continuation was queued.
    private var cancelled: Set<UUID> = []

    public init(limit: Int = GitLimiter.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Changes the limit; a higher one starts waiting callers right away.
    public func setLimit(_ newLimit: Int) {
        let ready = lock.withLock {
            limit = max(1, newLimit)
            return dequeueReady()
        }
        ready.forEach { $0.resume() }
    }

    /// Runs `body` once a slot is free.
    public func withSlot<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if running < limit {
                        running += 1
                        return .success(())
                    }
                    waiters.append((id, continuation))
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
                if let index = waiters.firstIndex(where: { $0.id == id }) {
                    return waiters.remove(at: index).continuation
                }
                cancelled.insert(id)
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
        // A slot was granted; drop a cancellation marker that arrived too late to matter.
        lock.withLock { _ = cancelled.remove(id) }
    }

    private func release() {
        let ready = lock.withLock {
            running -= 1
            return dequeueReady()
        }
        ready.forEach { $0.resume() }
    }

    /// Hands free slots to the longest-waiting callers. Call with the lock held.
    private func dequeueReady() -> [CheckedContinuation<Void, Error>] {
        var ready: [CheckedContinuation<Void, Error>] = []
        while running < limit, !waiters.isEmpty {
            running += 1
            ready.append(waiters.removeFirst().continuation)
        }
        return ready
    }
}
