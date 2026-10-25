import Foundation
import Testing
@testable import GroveCore

@Suite struct DebugLogTests {
    private func lines(_ log: DebugLog) throws -> [[String: Any]] {
        try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("grove-debug-\(UUID().uuidString)")
    }

    @Test func recordsRunsWithWaitAndOutputSize() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try DebugLog(directory: dir)
        // One slot: the second run waits for the first.
        let git = GitRunner(limiter: GitLimiter(limit: 1), onRecord: { log.log($0) })
        async let a = git.run(["-c", "alias.slow=!sleep 0.3", "slow"])
        async let b = git.run(["version"])
        _ = try await (a, b)
        log.log("step", ["repo": "/r", "seconds": 1.5])

        let events = try lines(log)
        #expect(events.first?["event"] as? String == "session")
        let runs = events.filter { $0["event"] as? String == "git" }
        #expect(runs.count == 2)
        let version = try #require(runs.first { ($0["args"] as? [String]) == ["version"] })
        #expect(version["exit"] as? Int == 0)
        #expect((version["outBytes"] as? Int ?? 0) > 0)
        #expect(version["outLines"] as? Int == 1)
        // Whichever ran second waited about as long as the first ran.
        let waits = runs.compactMap { $0["wait"] as? Double }
        #expect(waits.max() ?? 0 > 0.1)
        #expect(events.last?["event"] as? String == "step")
    }

    @Test func closedLogWritesNothing() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try DebugLog(directory: dir)
        log.close()
        log.log("step")
        #expect(try lines(log).count == 1)
    }

    @Test func lineCount() {
        #expect(GitRunner.lineCount("") == 0)
        #expect(GitRunner.lineCount("a") == 1)
        #expect(GitRunner.lineCount("a\n") == 1)
        #expect(GitRunner.lineCount("a\nb") == 2)
        #expect(GitRunner.lineCount("a\0b\0") == 2)
    }

    @Test func clearDeletesOnlyLogs() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try DebugLog(directory: dir, start: .now.addingTimeInterval(-3600))
        let current = try DebugLog(directory: dir)
        try "x".write(to: dir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        #expect(DebugLog.files(in: dir) == [old.fileURL, current.fileURL])
        #expect(DebugLog.clear(in: dir) == 2)
        #expect(DebugLog.files(in: dir).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.txt").path))
    }
}
