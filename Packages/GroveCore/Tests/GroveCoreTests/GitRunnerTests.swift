import Foundation
import Testing
@testable import GroveCore

@Test func unicodeEscapesAreRestored() {
    #expect("The operation couldn\\U2019t be completed.".unescapingUnicode == "The operation couldn’t be completed.")
    #expect("plain \\Uxyz text".unescapingUnicode == "plain \\Uxyz text")
    #expect("nothing to do".unescapingUnicode == "nothing to do")
}

@Test func runsAreRecordedWithOutput() async throws {
    let records = Records()
    let git = GitRunner(onRecord: { records.add($0) })
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    _ = try await git.run(["--version"], in: dir)
    let ok = try #require(records.latest)
    #expect(ok.succeeded)
    #expect(ok.stdout.hasPrefix("git version"))
    #expect(records.count == 2) // started + finished

    _ = try? await git.run(["rev-parse", "--verify", "no-such-ref"], in: dir)
    let failed = try #require(records.latest)
    #expect(!failed.succeeded)
    #expect(failed.exitCode != 0)
    #expect(failed.stderr.contains("fatal"))
}

@Test func largeOutputIsReadCompletely() async throws {
    let git = GitRunner()
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    // Well beyond a pipe buffer (64 KB), through stdin and back out on stdout.
    let input = String(repeating: "0123456789abcdef\n", count: 20_000)
    let result = try await git.run(["hash-object", "--stdin", "--literally", "-t", "blob"], in: dir, input: Data(input.utf8))
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count == 40)
    let log = try await git.run(["log", "-p", "--all", "-3000"], in: dir)
    #expect(!log.stdout.isEmpty)
}

@Test func missingGitIsReportedAsLaunchFailure() async throws {
    let records = Records()
    let git = GitRunner(gitPath: "/nonexistent/git", onRecord: { records.add($0) })
    do {
        _ = try await git.run(["--version"])
        Issue.record("expected an error")
    } catch let error as GitError {
        #expect(error.launchFailure != nil)
        #expect(error.localizedDescription.hasPrefix("Couldn't start git --version"))
    }
    #expect(records.latest?.failure?.hasPrefix("Couldn't start git") == true)
}

@Test func queriesAreToldApartFromActions() {
    func record(_ args: String) -> GitRunRecord {
        GitRunRecord(id: UUID(), arguments: args.split(separator: " ").map(String.init), directory: nil, started: .now)
    }
    for query in ["status --porcelain=v2", "rev-parse HEAD", "worktree list --porcelain", "config --get remote.origin.url",
                  "for-each-ref refs/heads", "remote", "branch --show-current"] {
        #expect(record(query).isQuery, "\(query)")
    }
    for action in ["fetch --prune --no-progress origin", "pull --ff-only", "worktree add ../x feature",
                   "merge --ff-only origin/main", "config --add remote.origin.fetch x", "branch -D old"] {
        #expect(!record(action).isQuery, "\(action)")
    }
}

private final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GitRunRecord] = []
    func add(_ record: GitRunRecord) { lock.withLock { items.append(record) } }
    var latest: GitRunRecord? { lock.withLock { items.last } }
    var count: Int { lock.withLock { items.count } }
}
