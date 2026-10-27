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

    @Test func fastForwardFromSnapshotSkipsStatus() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let records = RunLog()
        _ = try await sb.clone("ffsnap", mode: .full)
        let repo = GitRepository(url: sb.root.appendingPathComponent("ffsnap"), git: GitRunner(onRecord: { records.add($0) }))
        try await sb.publish(3)
        try await repo.fetch()

        // Dirty: refused without running git.
        try "dirty".write(to: repo.url.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        var main = try #require(try await repo.snapshot().mainWorktree)
        records.reset()
        #expect(try await repo.fastForward(worktree: main) == .skipped("uncommitted changes"))
        #expect(records.total == 0)

        // Clean and behind: only the merge runs.
        try await sb.git.run(["checkout", "--", "file1.txt"], in: repo.url)
        main = try #require(try await repo.snapshot().mainWorktree)
        records.reset()
        #expect(try await repo.fastForward(worktree: main) == .updated(commits: 3))
        #expect(records.total == 1 && records.count("merge") == 1)

        // Up to date: nothing runs.
        main = try #require(try await repo.snapshot().mainWorktree)
        records.reset()
        #expect(try await repo.fastForward(worktree: main) == .upToDate)
        #expect(records.total == 0)
    }

    @Test func detailsFromKnownStatusMatchFullScan() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let records = RunLog()
        _ = try await sb.clone("known", mode: .full)
        let repo = GitRepository(url: sb.root.appendingPathComponent("known"), git: GitRunner(onRecord: { records.add($0) }))
        try await sb.git.run(["checkout", "-q", "-b", "topic"], in: repo.url)
        try await sb.commit(in: repo.url, file: "new.txt", content: "n")
        try await sb.git.run(["mv", "file1.txt", "renamed.txt"], in: repo.url)
        try await sb.git.run(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "rename"], in: repo.url)
        try await sb.publish(1)
        try await repo.fetch()

        // Clean: no working-tree scans, same result.
        var snap = try await repo.snapshot()
        var main = try #require(snap.mainWorktree)
        let full = await repo.worktreeDetails(path: main.path, primaryRef: snap.baseRef)
        records.reset()
        let lean = await repo.worktreeDetails(path: main.path, primaryRef: snap.baseRef, knownStatus: main.status)
        #expect(lean == full)
        #expect(records.count("ls-files") == 0 && records.count("merge-base") == 0)
        #expect(records.count("diff") == 1)
        let rename = try #require(lean.changedSinceBase.first { $0.path == "renamed.txt" })
        #expect(rename.status == "R" && rename.oldPath == "file1.txt")
        #expect(lean.changedSinceBase.first { $0.path == "new.txt" }?.status == "A")

        // Dirty with untracked files: scans as before.
        try "edit".write(to: repo.url.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        try "u".write(to: repo.url.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        snap = try await repo.snapshot()
        main = try #require(snap.mainWorktree)
        let dirtyFull = await repo.worktreeDetails(path: main.path, primaryRef: snap.baseRef)
        let dirtyLean = await repo.worktreeDetails(path: main.path, primaryRef: snap.baseRef, knownStatus: main.status)
        #expect(dirtyLean == dirtyFull)
        #expect(dirtyLean.uncommitted.map(\.status) == ["M", "?"])
    }

    @Test func traceCountsRunsOfOneOperation() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("trace", mode: .full)
        let trace = GitTrace(id: "op1")
        _ = try await GitTrace.$current.withValue(trace) { try await repo.snapshot() }
        let summary = trace.summary
        let calls = try #require(summary["gitCalls"] as? Int)
        let bySubcommand = try #require(summary["gitCallsBySubcommand"] as? [String: Int])
        #expect(calls > 0 && bySubcommand.values.reduce(0, +) == calls)
        #expect(bySubcommand["status"] == 1)
    }

    @Test func tuningPlanRespectsHooksSplitIndexAndSupport() {
        let fresh = RepoTuning.plan(fsmonitor: nil, untrackedCache: nil, manyFiles: nil, splitIndex: nil,
                                    writeCommitGraph: nil, fsmonitorAvailable: true)
        #expect(fresh.enabled.isEmpty && !fresh.isOptimized)
        // The suggestion leaves out the many-files index, which other git tools may not read.
        #expect(fresh.suggested == [.fsmonitor, .untrackedCache, .commitGraph])
        #expect(fresh.changes(to: fresh.suggested).map(\.option) == [.fsmonitor, .untrackedCache, .commitGraph])

        let hook = RepoTuning.plan(fsmonitor: ".git/hooks/query-watchman", untrackedCache: "true", manyFiles: nil,
                                   splitIndex: nil, writeCommitGraph: "true", fsmonitorAvailable: true)
        #expect(hook.isOptimized && hook.setting(.fsmonitor)?.isOn == true && hook.setting(.fsmonitor)?.unavailable != nil)
        #expect(hook.changes(to: []).map(\.option) == [.untrackedCache, .commitGraph])  // The hook stays.

        let split = RepoTuning.plan(fsmonitor: "true", untrackedCache: "true", manyFiles: nil, splitIndex: "true",
                                    writeCommitGraph: "true", fsmonitorAvailable: true)
        #expect(split.changes(to: [.fsmonitor, .untrackedCache, .commitGraph, .manyFiles]).isEmpty)

        let noDaemon = RepoTuning.plan(fsmonitor: "false", untrackedCache: nil, manyFiles: nil, splitIndex: nil,
                                       writeCommitGraph: "true", fsmonitorAvailable: false)
        #expect(noDaemon.suggested == [.untrackedCache, .commitGraph])

        // Many files implies the untracked cache.
        let many = RepoTuning.plan(fsmonitor: nil, untrackedCache: nil, manyFiles: "true", splitIndex: nil,
                                   writeCommitGraph: nil, fsmonitorAvailable: false)
        #expect(many.enabled == [.manyFiles, .untrackedCache])
    }

    @Test func tuningTurnsSettingsOnAndOff() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("tune", mode: .full)
        let indexURL = repo.url.appendingPathComponent(".git/index")
        func index() throws -> (version: UInt8, untrackedCache: Bool) {
            let data = try Data(contentsOf: indexURL)
            return (data[7], data.range(of: Data("UNTR".utf8)) != nil)
        }
        func config(_ key: String) async -> String? {
            await sb.git.outputIfSuccess(["config", "--local", "--get", key], in: repo.url)
        }

        // Without the monitor, so no daemon outlives the test.
        let wanted: Set<RepoTuning.Option> = [.untrackedCache, .manyFiles, .commitGraph]
        try await repo.applyTuning(await repo.tuning().changes(to: wanted))
        #expect(await config("core.untrackedCache") == "true")
        #expect(await config("feature.manyFiles") == "true")
        #expect(await config("fetch.writeCommitGraph") == "true")
        #expect(try index() == (4, true))  // The status wrote the new format and the untracked cache.
        let graphs = repo.url.appendingPathComponent(".git/objects/info/commit-graphs")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: graphs.path)).isEmpty)
        #expect(await repo.tuning().enabled.isSuperset(of: wanted))

        // Off again: the index is back in the classic format, without the cache.
        try await repo.applyTuning(await repo.tuning().changes(to: [.commitGraph]))
        #expect(await config("feature.manyFiles") == "false")
        #expect(await config("core.untrackedCache") == "false")
        let after = try index()
        #expect(after.version <= 3 && !after.untrackedCache)
        #expect(await sb.git.outputIfSuccess(["status", "--porcelain"], in: repo.url) == "")
    }

    @Test func snapshotReportsProgressInOrder() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("progress", mode: .full)
        for name in ["one", "two"] {
            try await repo.addWorktree(branch: "origin/main", at: sb.root.appendingPathComponent("progress-\(name)"))
        }
        let reports = Reports()
        let snap = try await repo.snapshot { reports.add($0) }
        let steps = reports.all.map(\.step).filter { $0.hasPrefix("status") }
        #expect(steps == ["status 0/3", "status 1/3", "status 2/3", "status 3/3"])
        #expect(reports.all.first?.pendingWorktrees == Set(snap.worktrees.map(\.path)))
        #expect(reports.all.last { $0.step.hasPrefix("status") }?.pendingWorktrees.isEmpty == true)
    }

    @Test func snapshotWritesIndexOnlyWhereAllowed() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("writeindex", mode: .full)
        try await sb.git.run(["config", "--local", "core.untrackedCache", "true"], in: repo.url)
        let index = repo.url.appendingPathComponent(".git/index")
        func hasUntrackedCache() throws -> Bool { try Data(contentsOf: index).range(of: Data("UNTR".utf8)) != nil }

        _ = try await repo.snapshot()
        #expect(try !hasUntrackedCache())  // Status normally leaves the index alone.
        var options = GitRepository.SnapshotOptions()
        options.writeIndexIn = [repo.url.path]
        _ = try await repo.snapshot(options: options)
        #expect(try hasUntrackedCache())
    }

    @Test func leanSnapshotSkipsRemoteBranchesUntilAsked() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        for branch in ["a", "b"] { try await sb.publish(1, branch: branch) }
        let records = RunLog()
        _ = try await sb.clone("lean-remote", mode: .full)
        let repo = GitRepository(url: sb.root.appendingPathComponent("lean-remote"),
                                 git: GitRunner(onRecord: { records.add($0) }))
        try await sb.git.run(["branch", "--track", "a", "origin/a"], in: repo.url)

        let full = try await repo.snapshot()
        let lean = try await repo.snapshot(options: .init(remoteBranches: false))
        #expect(full.remoteBranches.map(\.name).sorted() == ["a", "b", "main"])
        #expect(lean.remoteBranches.isEmpty && !lean.remoteBranchesListed)
        // Everything else matches: primary branch, comparisons and tracking come from local refs.
        #expect(lean.primaryBranch == full.primaryBranch && lean.baseRef == full.baseRef && lean.baseSHA == full.baseSHA)
        #expect(lean.branches == full.branches)
        #expect(lean.worktrees == full.worktrees)

        let listed = try await repo.remoteBranches(remote: "origin")
        #expect(Set(listed.map(\.name)) == ["a", "b", "main"])
        #expect(listed.allSatisfy { !$0.commit.subject.isEmpty })
    }

    @Test func fetchCanSkipAutoGCAndPrune() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let records = RunLog()
        _ = try await sb.clone("fetchopts", mode: .full)
        let repo = GitRepository(url: sb.root.appendingPathComponent("fetchopts"), git: GitRunner(onRecord: { records.add($0) }))
        try await sb.publish(1, branch: "gone")
        try await repo.fetch()
        try await sb.git.run(["push", "-q", "origin", ":gone"], in: sb.publisher)

        try await repo.fetch(options: .init(autoGC: false, prune: false))
        #expect(records.arguments("fetch").last?.contains("--no-auto-gc") == true)
        #expect(await sb.git.outputIfSuccess(["rev-parse", "--verify", "--quiet", "origin/gone"], in: repo.url) != nil)
        try await repo.fetch()
        #expect(await sb.git.outputIfSuccess(["rev-parse", "--verify", "--quiet", "origin/gone"], in: repo.url) == nil)
    }

    @Test func statusCanSkipUntrackedFiles() async throws {
        let sb = try await Sandbox()
        defer { sb.cleanup() }
        let repo = try await sb.clone("nountracked", mode: .full)
        try "u".write(to: repo.url.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)

        let snap = try await repo.snapshot(options: .init(untrackedFiles: false))
        let main = try #require(snap.mainWorktree)
        #expect(main.status.untracked == 0 && !main.status.untrackedCounted && !main.status.isClean)
        // Details still list them: the status couldn't rule them out.
        let details = await repo.worktreeDetails(path: main.path, primaryRef: snap.baseRef, knownStatus: main.status)
        #expect(details.uncommitted.map(\.path) == ["scratch.txt"])
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

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GitRepository.SnapshotProgress] = []
    func add(_ item: GitRepository.SnapshotProgress) { lock.withLock { items.append(item) } }
    var all: [GitRepository.SnapshotProgress] { lock.withLock { items } }
}

private final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [GitRunRecord] = []
    func add(_ record: GitRunRecord) { lock.withLock { if record.finished == nil { started.append(record) } } }
    func reset() { lock.withLock { started = [] } }
    func count(_ command: String) -> Int { lock.withLock { started.filter { $0.arguments.first == command }.count } }
    var total: Int { lock.withLock { started.count } }
    func arguments(_ command: String) -> [[String]] { lock.withLock { started.filter { $0.arguments.first == command }.map(\.arguments) } }
}
