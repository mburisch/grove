import Foundation
import Testing
@testable import GroveCore

struct DiffTests {
    @Test func parsesHunksWithLineNumbers() {
        let output = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@ header
         one
        -two
        +TWO
         three
        @@ -10,2 +10,3 @@
         ten
        +ten and a half
         eleven
        \\ No newline at end of file

        """
        let diff = GitParsers.parseUnifiedDiff(output)
        #expect(!diff.isBinary && !diff.truncated)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].header == "@@ -1,3 +1,3 @@ header")
        #expect(diff.hunks[0].lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(diff.hunks[0].lines[1].oldNumber == 2 && diff.hunks[0].lines[1].newNumber == nil)
        #expect(diff.hunks[0].lines[2].newNumber == 2 && diff.hunks[0].lines[2].text == "TWO")
        #expect(diff.hunks[0].lines[3].oldNumber == 3 && diff.hunks[0].lines[3].newNumber == 3)
        let second = diff.hunks[1].lines
        #expect(second.map(\.kind) == [.context, .added, .context, .note])
        #expect(second[2].oldNumber == 11 && second[2].newNumber == 12)
        #expect(second[3].text == "No newline at end of file")
    }

    @Test func binaryAndEmpty() {
        let binary = GitParsers.parseUnifiedDiff("diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n")
        #expect(binary.isBinary && binary.hunks.isEmpty)
        #expect(GitParsers.parseUnifiedDiff("") == FileDiff())
    }

    @Test func truncatesLongDiffs() {
        let lines = (0..<(GitParsers.maxDiffLines + 10)).map { "+\($0)" }
        let diff = GitParsers.parseUnifiedDiff("@@ -0,0 +1,\(lines.count) @@\n" + lines.joined(separator: "\n"))
        #expect(diff.truncated)
        #expect(diff.hunks[0].lines.count == GitParsers.maxDiffLines)
    }

    @Test func fileDiffInEachScope() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("diffs", mode: .full)
        let wt = repo.url.path
        let primary = try #require(try await repo.snapshot().baseRef)

        // Uncommitted change to a tracked file.
        try "v1 changed\n".write(to: repo.url.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        let modified = await repo.fileDiff(FileChange(status: "M", path: "file1.txt"), scope: .uncommitted(worktree: wt))
        #expect(modified.hunks.flatMap(\.lines).filter { $0.kind == .removed }.map(\.text) == ["v1"])
        #expect(modified.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["v1 changed"])
        let sinceBase = await repo.fileDiff(FileChange(status: "M", path: "file1.txt"), scope: .sinceBase(worktree: wt, primaryRef: primary))
        #expect(sinceBase == modified)

        // Untracked: the whole file is added.
        try "a\nb\n".write(to: repo.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let untracked = await repo.fileDiff(FileChange(status: "?", path: "new.txt"), scope: .uncommitted(worktree: wt))
        #expect(untracked.hunks.flatMap(\.lines).map(\.text) == ["a", "b"])
        #expect(untracked.hunks.flatMap(\.lines).allSatisfy { $0.kind == .added })

        // A branch without a worktree, compared from its fork point.
        try await sb.git.run(["branch", "feature"], in: repo.url)
        let other = sb.root.appendingPathComponent("feature-wt")
        try await repo.addWorktree(branch: "feature", at: other)
        try await sb.commit(in: other, file: "feature.txt", content: "one\n")
        try await repo.removeWorktree(path: other.path, discardingChanges: false)
        let branch = await repo.fileDiff(FileChange(status: "A", path: "feature.txt"), scope: .branch(name: "feature", primaryRef: primary))
        #expect(branch.hunks.flatMap(\.lines).map(\.text) == ["one"])
    }

    private func lines(_ kinds: String) -> [DiffLine] {
        kinds.map { c in
            DiffLine(kind: c == "+" ? .added : c == "-" ? .removed : .context, oldNumber: nil, newNumber: nil, text: "")
        }
    }

    @Test func foldsLongUnchangedRuns() {
        // 10 unchanged, a change, 10 unchanged, a change, 10 unchanged.
        let diff = lines(String(repeating: " ", count: 10) + "+" + String(repeating: " ", count: 10) + "-"
                         + String(repeating: " ", count: 10))
        #expect(DiffFolding.segments(diff) == [
            .folded(0..<7), .lines(7..<14), .folded(14..<18), .lines(18..<25), .folded(25..<32),
        ])
        #expect(DiffFolding.changeStarts(diff) == [10, 21])
    }

    @Test func keepsShortRunsAndAllChanges() {
        #expect(DiffFolding.segments(lines("++--")) == [.lines(0..<4)])
        // A gap of 8 between changes would fold only 2 lines, so it stays.
        #expect(DiffFolding.segments(lines("+" + String(repeating: " ", count: 8) + "+")) == [.lines(0..<10)])
        #expect(DiffFolding.segments([]) == [])
        #expect(DiffFolding.changeStarts(lines("+-  -+")) == [0, 4])
    }

    @Test func fullContextReturnsTheWholeFile() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("full", mode: .full)
        let text = (1...20).map { "line \($0)" }
        try await sb.commit(in: repo.url, file: "long.txt", content: text.joined(separator: "\n") + "\n")
        var changed = text
        changed[9] = "line ten"
        try (changed.joined(separator: "\n") + "\n").write(to: repo.url.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)

        let full = await repo.fileDiff(FileChange(status: "M", path: "long.txt"), scope: .uncommitted(worktree: repo.url.path))
        let all = full.hunks.flatMap(\.lines)
        #expect(full.hunks.count == 1)
        #expect(all.count == 21)
        #expect(all.filter { $0.kind == .context }.compactMap(\.newNumber) == Array(1...9) + Array(11...20))
        let short = await repo.fileDiff(FileChange(status: "M", path: "long.txt"), scope: .uncommitted(worktree: repo.url.path),
                                        fullContext: false)
        #expect(short.hunks.flatMap(\.lines).count == 8)
    }
}
