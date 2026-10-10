import Foundation
import Testing
@testable import GroveCore

@Suite struct LargeRepoTests {
    private func sha(_ ref: String, in dir: URL, _ git: GitRunner) async -> String? {
        await git.outputIfSuccess(["rev-parse", "--verify", "--quiet", ref], in: dir)
    }

    @Test func narrowFetchGetsPrimaryAndUpstreamsOnly() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        for branch in ["a", "b", "c"] { try await sb.publish(1, branch: branch) }
        let repo = try await sb.clone("narrow", mode: .full)
        for branch in ["a", "b"] { try await sb.git.run(["branch", "--track", branch, "origin/\(branch)"], in: repo.url) }
        let oldC = await sha("origin/c", in: repo.url, sb.git)

        // The remote moves on: new commits everywhere, b deleted, d created.
        try await sb.publish(1, branch: "main")
        try await sb.publish(1, branch: "a")
        try await sb.publish(1, branch: "c")
        try await sb.publish(1, branch: "d")
        try await sb.git.run(["push", "-q", "origin", ":b"], in: sb.publisher)

        try await repo.fetch(options: .init(scope: .primaryAndLocal, tags: false))
        #expect(await sha("origin/main", in: repo.url, sb.git) == (await sha("main", in: sb.remote, sb.git)))
        #expect(await sha("origin/a", in: repo.url, sb.git) == (await sha("a", in: sb.remote, sb.git)))
        #expect(await sha("origin/c", in: repo.url, sb.git) == oldC)  // No local branch: not fetched.
        #expect(await sha("origin/d", in: repo.url, sb.git) == nil)
        #expect(await sha("origin/b", in: repo.url, sb.git) == nil)  // Deleted on the remote: pruned.
        let b = try #require(try await repo.snapshot().branches.first { $0.name == "b" })
        #expect(b.upstreamGone)

        // A full fetch still gets everything.
        try await repo.fetch()
        #expect(await sha("origin/d", in: repo.url, sb.git) != nil)
    }

    @Test func unchangedCommitsAreNotComparedAgain() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let records = RunLog()
        let git = GitRunner(onRecord: { records.add($0) })
        _ = try await sb.clone("cache", mode: .full)
        let repo = GitRepository(url: sb.root.appendingPathComponent("cache"), git: git)
        try await sb.git.run(["branch", "feature", "HEAD~2"], in: repo.url)
        let cache = ComparisonCache()

        let first = try await repo.snapshot(cache: cache)
        #expect(records.count("rev-list") > 0)
        records.reset()
        let second = try await repo.snapshot(cache: cache)
        #expect(records.count("rev-list") == 0)
        #expect(records.count("diff") == 1)  // Only the uncommitted line count.
        #expect(second.branches == first.branches)
        #expect(second.branches.first { $0.name == "feature" }?.versusPrimary == AheadBehind(ahead: 0, behind: 2))

        // A moved branch is compared again.
        try await sb.git.run(["branch", "-f", "feature", "HEAD~1"], in: repo.url)
        records.reset()
        let third = try await repo.snapshot(cache: cache)
        #expect(records.count("rev-list") == 1)
        #expect(third.branches.first { $0.name == "feature" }?.versusPrimary == AheadBehind(ahead: 0, behind: 1))
    }

    @Test func worktreesOnlyComparesOthersOnDemand() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("lean", mode: .full)
        try await sb.git.run(["branch", "feature", "HEAD~2"], in: repo.url)
        let cache = ComparisonCache()
        let options = GitRepository.SnapshotOptions(compareAllBranches: false, lineCounts: false)

        let snap = try await repo.snapshot(options: options, cache: cache)
        #expect(snap.branches.first { $0.name == "feature" }?.versusPrimary == nil)
        #expect(snap.mainWorktree?.versusPrimary == .zero)  // Worktrees are always compared.
        #expect(snap.mainWorktree?.uncommittedDiff == .zero)

        // Compared when selected, then kept by later snapshots while the commits stay the same.
        let feature = try #require(snap.branches.first { $0.name == "feature" })
        let target = CompareTarget(ref: try #require(snap.baseRef), sha: try #require(snap.baseSHA))
        _ = await repo.comparison(of: feature.commit.sha, to: target, diff: false, cache: cache)
        let again = try await repo.snapshot(options: options, cache: cache)
        #expect(again.branches.first { $0.name == "feature" }?.versusPrimary == AheadBehind(ahead: 0, behind: 2))
    }

    @Test func storageAndPrefetch() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("store", mode: .full)
        let storage = try #require(await repo.storage())
        #expect(storage.totalBytes > 0)
        #expect(!storage.needsCleanUp)

        try await sb.git.run(["update-ref", "refs/prefetch/remotes/origin/main", "HEAD"], in: repo.url)
        #expect(await repo.prefetchStatus().refCount == 1)
        try await repo.setPrefetch(enabled: false)
        let off = await repo.prefetchStatus()
        #expect(off.refCount == 0 && !off.enabled)
        try await repo.setPrefetch(enabled: true)
        #expect(await sb.git.outputIfSuccess(["config", "--local", "--get", "maintenance.prefetch.enabled"], in: repo.url) == nil)

        try await repo.cleanUp()
        #expect(try #require(await repo.storage()).packs == 1)
    }

    @Test func parsesCountObjects() throws {
        let storage = try #require(RepoStorage.parse("""
        count: 12
        size: 48
        in-pack: 3000000
        packs: 140
        size-pack: 18874368
        prune-packable: 0
        garbage: 0
        size-garbage: 0
        """))
        #expect(storage.packs == 140)
        #expect(storage.totalBytes == (48 + 18_874_368) * 1024)
        #expect(storage.needsCleanUp)
        #expect(RepoStorage.parse("nonsense") == nil)
    }

    @Test func profilesFillInSettings() {
        #expect(RepoProfile.detect(storageBytes: 300 << 20) == .normal)
        #expect(RepoProfile.detect(storageBytes: 4 << 30) == .large)

        var config = AppConfig()
        config.defaultFetchIntervalMinutes = 15
        let normal = config.effectiveSettings(for: "/r", detected: .normal)
        #expect(normal.fetchScope == .all && normal.compareAllBranches && normal.lineCounts && normal.fetchIntervalMinutes == 15)
        let large = config.effectiveSettings(for: "/r", detected: .large)
        #expect(large.fetchScope == .primaryAndLocal && !large.compareAllBranches && !large.lineCounts && !large.fetchTags)
        #expect(large.fetchIntervalMinutes == 60)
        config.defaultFetchIntervalMinutes = 0
        #expect(config.effectiveSettings(for: "/r", detected: .large).fetchIntervalMinutes == 0)

        // An explicit profile beats detection; single settings beat the profile.
        var custom = RepoSettings()
        custom.profile = .normal
        custom.lineCounts = false
        config.repoSettings["/r"] = custom
        let mixed = config.effectiveSettings(for: "/r", detected: .large)
        #expect(mixed.profile == .normal && mixed.fetchScope == .all && !mixed.lineCounts)
        #expect(custom.hasOverrides)
        custom.applyDefaults(.large)
        #expect(!custom.hasOverrides && custom.profile == .large)
    }
}

private final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [GitRunRecord] = []
    func add(_ record: GitRunRecord) { lock.withLock { if record.finished == nil { started.append(record) } } }
    func reset() { lock.withLock { started = [] } }
    func count(_ command: String) -> Int { lock.withLock { started.filter { $0.arguments.first == command }.count } }
}
