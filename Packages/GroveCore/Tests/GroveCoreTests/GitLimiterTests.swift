import Foundation
import Testing
@testable import GroveCore

@Test func limiterCapsConcurrentRuns() async throws {
    let limiter = GitLimiter(limit: 3)
    let gauge = Gauge()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            group.addTask {
                try await limiter.withSlot {
                    gauge.enter()
                    try await Task.sleep(for: .milliseconds(10))
                    gauge.leave()
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(gauge.peak == 3)
}

@Test func cancelledWaiterLeavesTheQueue() async throws {
    let limiter = GitLimiter(limit: 1)
    let holder = Task { try await limiter.withSlot { try await Task.sleep(for: .milliseconds(200)) } }
    try await Task.sleep(for: .milliseconds(20))
    let waiter = Task { try await limiter.withSlot { "ran" } }
    try await Task.sleep(for: .milliseconds(20))
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    try await holder.value
    // The slot is free again for the next caller.
    #expect(try await limiter.withSlot { 1 } == 1)
}

@Test func limitedRunnerStillRunsGit() async throws {
    let git = GitRunner(limiter: GitLimiter(limit: 2))
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
            group.addTask { _ = try await git.run(["--version"], in: dir) }
        }
        try await group.waitForAll()
    }
}

private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}
