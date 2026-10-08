import Foundation
import Testing
@testable import GroveCore

/// A bare "remote" plus a working clone used to publish commits to it, all in a temp directory.
struct Sandbox {
    let root: URL
    let remote: URL
    let publisher: URL
    let git = GitRunner()

    var remoteURL: String { "file://" + remote.path }

    init() async throws {
        // Resolve /var -> /private/var so paths match what git reports.
        let tmp = URL(fileURLWithPath: realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? "/tmp")
        root = tmp.appendingPathComponent("grove-tests-\(UUID().uuidString)")
        remote = root.appendingPathComponent("remote.git")
        publisher = root.appendingPathComponent("publisher")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git.run(["init", "-q", "--bare", "-b", "main", remote.path])
        try await git.run(["config", "uploadpack.allowFilter", "true"], in: remote)
        try await git.run(["config", "uploadpack.allowAnySHA1InWant", "true"], in: remote)
        try await git.run(["clone", "-q", remoteURL, publisher.path])
        for i in 1...5 { try await commit(in: publisher, file: "file\(i).txt", content: "v\(i)") }
        try await git.run(["push", "-q", "origin", "HEAD:main"], in: publisher)
        try await git.run(["remote", "set-head", "origin", "main"], in: publisher)
    }

    func commit(in dir: URL, file: String, content: String) async throws {
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await git.run(["add", file], in: dir)
        try await git.run(["-c", "user.name=Test", "-c", "user.email=t@example.com", "commit", "-q", "-m", "change \(file)"], in: dir)
    }

    /// Adds commits on the remote's main branch.
    func publish(_ count: Int, branch: String = "main") async throws {
        for i in 0..<count {
            try await commit(in: publisher, file: "pub-\(UUID().uuidString.prefix(6))-\(i).txt", content: "x")
        }
        try await git.run(["push", "-q", "origin", "HEAD:\(branch)"], in: publisher)
    }

    func clone(_ name: String, mode: CheckoutMode) async throws -> GitRepository {
        let dest = root.appendingPathComponent(name)
        try await GitRepository.clone(remoteURL, to: dest, mode: mode, git: git)
        return GitRepository(url: dest, git: git)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized)
struct RepositoryTests {
    @Test func fullCloneTracksAheadBehind() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("full", mode: .full)

        var snap = try await repo.snapshot()
        #expect(snap.mode == .full)
        #expect(snap.primaryBranch == "main")
        #expect(snap.remoteName == "origin")
        #expect(snap.worktrees.count == 1)
        #expect(snap.mainWorktree?.versusPrimary == .zero)

        try await sb.publish(2)
        try await repo.fetch()
        try await sb.commit(in: repo.url, file: "local.txt", content: "mine")
        snap = try await repo.snapshot()
        let main = try #require(snap.branches.first { $0.name == "main" })
        #expect(main.tracking == AheadBehind(ahead: 1, behind: 2))
        #expect(main.versusPrimary == AheadBehind(ahead: 1, behind: 2))
        #expect(snap.mainWorktree?.committedDiff.files == 1)
        #expect(snap.lastFetchDate != nil)

        // Diverged: ff must refuse.
        let outcome = try await repo.fastForward(worktree: repo.url.path)
        #expect(outcome == .skipped("diverged (1 local commits)"))
    }

    @Test func fastForwardRespectsDirtyTree() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("ff", mode: .full)
        try await sb.publish(3)
        try await repo.fetch()

        try "dirty".write(to: repo.url.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        #expect(try await repo.fastForward(worktree: repo.url.path) == .skipped("uncommitted changes"))

        try await sb.git.run(["checkout", "--", "file1.txt"], in: repo.url)
        // Untracked files don't block.
        try "new".write(to: repo.url.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        #expect(try await repo.fastForward(worktree: repo.url.path) == .updated(commits: 3))
        #expect(try await repo.fastForward(worktree: repo.url.path) == .upToDate)
    }

    @Test func worktreesAndBranches() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        try await sb.git.run(["checkout", "-q", "-b", "feature"], in: sb.publisher)
        try await sb.publish(1, branch: "feature")
        let repo = try await sb.clone("wt", mode: .full)

        let wtPath = sb.root.appendingPathComponent("wt-feature")
        try await repo.addWorktree(branch: "feature", at: wtPath)
        try await sb.commit(in: wtPath, file: "f.txt", content: "f")

        let snap = try await repo.snapshot()
        #expect(snap.worktrees.count == 2)
        let wt = try #require(snap.worktrees.first { $0.branch == "feature" })
        #expect(!wt.isMain)
        #expect(wt.versusPrimary == AheadBehind(ahead: 2, behind: 0))
        #expect(wt.tracking == AheadBehind(ahead: 1, behind: 0))
        #expect(wt.committedDiff.files == 2)
        let branch = try #require(snap.branches.first { $0.name == "feature" })
        #expect(branch.worktreePath == wtPath.path)
        #expect(snap.remoteBranches.map(\.name).sorted() == ["feature", "main"])

        try "edit".write(to: wtPath.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: wtPath.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        let details = await repo.worktreeDetails(path: wtPath.path, primaryRef: snap.baseRef)
        #expect(details.head?.subject == "change f.txt")
        #expect(details.uncommitted.map(\.path) == ["file1.txt", "scratch.txt"])
        #expect(details.uncommitted.map(\.status) == ["M", "?"])
        #expect(details.commitsAhead.count == 2)
        // The published feature commit, the local f.txt commit, and the uncommitted edit to file1.txt.
        let sinceBase = details.changedSinceBase.map(\.path)
        #expect(sinceBase.count == 3)
        #expect(sinceBase.contains("f.txt") && sinceBase.contains("file1.txt"))
        #expect(details.changedSinceBase.allSatisfy { $0.status != "?" })
    }

    @Test func repoWithoutRemoteComparesToLocalMain() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let dir = sb.root.appendingPathComponent("local")
        try await sb.git.run(["init", "-q", "-b", "main", dir.path])
        try await sb.commit(in: dir, file: "a.txt", content: "a")
        let repo = GitRepository(url: dir, git: sb.git)
        let wtPath = sb.root.appendingPathComponent("local-topic")
        try await sb.git.run(["worktree", "add", "-q", "-b", "topic", wtPath.path], in: dir)
        try await sb.commit(in: wtPath, file: "b.txt", content: "b")

        let snap = try await repo.snapshot()
        #expect(snap.remoteName == nil)
        #expect(snap.primaryBranch == "main")
        #expect(snap.baseRef == "main")
        let wt = try #require(snap.worktrees.first { $0.branch == "topic" })
        #expect(wt.versusPrimary == AheadBehind(ahead: 1, behind: 0))
        let details = await repo.worktreeDetails(path: wtPath.path, primaryRef: snap.baseRef)
        #expect(details.changedSinceBase.map(\.path) == ["b.txt"])
    }

    @Test func fastForwardBranchWithoutWorktree() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("branch", mode: .full)
        try await sb.git.run(["checkout", "-q", "-b", "other"], in: repo.url)
        try await sb.publish(2)
        try await repo.fetch()
        let main = try #require(try await repo.snapshot().branches.first { $0.name == "main" })
        #expect(main.worktreePath == nil)
        #expect(try await repo.fastForward(branch: main) == .updated(commits: 2))
        let after = try #require(try await repo.snapshot().branches.first { $0.name == "main" })
        #expect(after.tracking == .zero)
    }

    @Test func branchWithoutWorktreeHasDiffAndDetails() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("details", mode: .full)
        try await sb.git.run(["checkout", "-q", "-b", "feature"], in: repo.url)
        try await sb.commit(in: repo.url, file: "feature.txt", content: "one\ntwo\n")
        try await sb.git.run(["checkout", "-q", "main"], in: repo.url)

        let snap = try await repo.snapshot()
        let feature = try #require(snap.branches.first { $0.name == "feature" })
        #expect(feature.worktreePath == nil)
        #expect(feature.versusPrimary == AheadBehind(ahead: 1, behind: 0))
        #expect(feature.committedDiff == DiffStat(files: 1, insertions: 2, deletions: 0))
        // Checked-out branches get their diff from the worktree instead.
        #expect(snap.branches.first { $0.name == "main" }?.committedDiff == nil)

        let details = await repo.branchDetails(name: "feature", primaryRef: snap.baseRef)
        #expect(details.head?.subject == "change feature.txt")
        #expect(details.commitsAhead.map(\.subject) == ["change feature.txt"])
        #expect(details.changedSinceBase.map(\.path) == ["feature.txt"])
        #expect(details.uncommitted.isEmpty)
    }

    @Test func shallowCloneStaysShallowAcrossFetch() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("shallow", mode: .shallow)
        #expect(try await repo.snapshot().mode == .shallow)

        try await sb.publish(2)
        try await repo.fetch()
        let snap = try await repo.snapshot()
        #expect(snap.mode == .shallow)
        #expect(snap.mainWorktree?.tracking == AheadBehind(ahead: 0, behind: 2))
        #expect(try await repo.fastForward(worktree: repo.url.path) == .updated(commits: 2))
        let count = try await sb.git.output(["rev-list", "--count", "HEAD"], in: repo.url)
        #expect(count == "3")
    }

    @Test func bloblessCloneStaysBlobless() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("blobless", mode: .blobless)
        #expect(try await repo.snapshot().mode == .blobless)
        try await sb.publish(1)
        try await repo.fetch()
        #expect(try await repo.snapshot().mode == .blobless)
        #expect(try await repo.fastForward(worktree: repo.url.path) == .updated(commits: 1))
    }

    @Test func conversions() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        try await sb.git.run(["checkout", "-q", "-b", "feature"], in: sb.publisher)
        try await sb.publish(1, branch: "feature")
        try await sb.git.run(["checkout", "-q", "main"], in: sb.publisher)

        let repo = try await sb.clone("convert", mode: .full)
        func commitCount() async throws -> String {
            try await sb.git.output(["rev-list", "--count", "origin/main"], in: repo.url)
        }
        /// Whether an object is stored locally (lazy fetching from the promisor disabled).
        func hasObject(_ rev: String) async throws -> Bool {
            let result = try await sb.git.run(
                ["--no-lazy-fetch", "cat-file", "-e", rev],
                in: repo.url, check: false)
            return result.exitCode == 0
        }
        let oldCommit = try await sb.git.output(["rev-parse", "HEAD~2"], in: repo.url)
        let oldBlob = try await sb.git.output(["rev-parse", "HEAD~2:file1.txt"], in: repo.url)
        // Rewrite file1.txt upstream so its original blob only exists in history.
        try await sb.commit(in: sb.publisher, file: "file1.txt", content: "rewritten")

        try await sb.publish(1, branch: "main")
        try await repo.convert(to: .shallow)
        #expect(try await !hasObject(oldCommit), "history beyond the shallow boundary is pruned")
        var snap = try await repo.snapshot()
        #expect(snap.mode == .shallow)
        #expect(snap.remoteBranches.map(\.name) == ["main"])
        #expect(try await commitCount() == "1")
        // The clean, non-diverged local main followed the new tip.
        #expect(snap.mainWorktree?.tracking == .zero)

        try await repo.convert(to: .full)
        snap = try await repo.snapshot()
        #expect(snap.mode == .full)
        #expect(try await commitCount() == "7")
        #expect(try await hasObject(oldCommit))
        #expect(snap.remoteBranches.map(\.name).sorted() == ["feature", "main"])

        try await repo.convert(to: .blobless)
        snap = try await repo.snapshot()
        #expect(snap.mode == .blobless)
        #expect(try await commitCount() == "7")
        #expect(try await !hasObject(oldBlob), "historical blobs are dropped")
        #expect(try await hasObject("HEAD:file1.txt"), "checked-out blobs are kept")
        let fsck = try await sb.git.run(["fsck", "--connectivity-only", "--no-dangling"], in: repo.url, check: false)
        #expect(fsck.exitCode == 0, "\(fsck.stderr)")
        // Status still works; checked-out files are present.
        #expect(snap.mainWorktree?.status.isClean == true)

        try await repo.convert(to: .full)
        snap = try await repo.snapshot()
        #expect(snap.mode == .full)
        #expect(try await hasObject(oldBlob))
        // Every object is local again: fsck finds nothing missing.
        try await sb.git.run(["-c", "remote.origin.promisor=false", "fsck", "--connectivity-only", "--no-progress"], in: repo.url)
    }

    @Test func movedTagIsReportedAndFixable() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        try await sb.git.run(["tag", "latest"], in: sb.publisher)
        try await sb.git.run(["push", "-q", "origin", "latest"], in: sb.publisher)
        let repo = try await sb.clone("full", mode: .full)
        // Auto-followed tags are never updated; the rejection needs tags fetched explicitly.
        try await sb.git.run(["config", "remote.origin.tagOpt", "--tags"], in: repo.url)

        // The remote moves `latest` to a new commit; a plain fetch refuses to overwrite it.
        try await sb.publish(1)
        try await sb.git.run(["tag", "-f", "latest"], in: sb.publisher)
        try await sb.git.run(["push", "-q", "-f", "origin", "latest"], in: sb.publisher)
        let error = await #expect(throws: GitError.self) { try await repo.fetch() }
        #expect(error?.clobberedTags == ["latest"])
        #expect(error?.errorDescription?.hasPrefix("Tag “latest” moved on the remote") == true)

        try await repo.updateTags(["latest"])
        let local = try await sb.git.output(["rev-parse", "latest"], in: repo.url)
        let remote = try await sb.git.output(["rev-parse", "latest"], in: sb.publisher)
        #expect(local == remote)
        try await repo.fetch()
    }

    @Test func emptyRepositoryHasNoCommitsAndNoPrimary() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let dir = sb.root.appendingPathComponent("empty")
        try await sb.git.run(["init", "-q", "-b", "main", dir.path])
        let snap = try await GitRepository(url: dir, git: sb.git).snapshot()
        #expect(snap.mainWorktree?.branch == "main")
        #expect(snap.mainWorktree?.hasCommits == false)
        #expect(snap.primaryBranch == nil)
    }

    @Test func scanner() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let nested = sb.root.appendingPathComponent("group/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try await sb.git.run(["init", "-q", nested.appendingPathComponent("repoA").path])
        let repo = try await sb.clone("cloned", mode: .full)
        // A linked worktree has a `.git` file and must not show up as its own repository.
        try await sb.git.run(["worktree", "add", "-q", "-b", "wt", sb.root.appendingPathComponent("linked").path], in: repo.url)

        let names = { (depth: Int) in RepoScanner.scan(root: sb.root, maxDepth: depth).map(\.lastPathComponent) }
        #expect(names(1) == ["cloned", "publisher"])
        #expect(names(3).sorted() == ["cloned", "publisher", "repoA"])
    }
}
