import Foundation

/// Typed git operations on one local repository. Only fetch, fast-forward, worktree creation,
/// and checkout-mode conversion write anything, and none of them touch the remote.
public struct GitRepository: Sendable {
    public let url: URL
    public let git: GitRunner

    public init(url: URL, git: GitRunner) {
        self.url = url
        self.git = git
    }

    public static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    // MARK: - Snapshot

    /// What a snapshot computes beyond refs and working-tree status.
    public struct SnapshotOptions: Sendable, Hashable {
        /// Compare recent branches (up to `maxComparisons`) with the primary branch. When false, only
        /// branches checked out in a worktree are compared; others keep results already in the cache.
        public var compareAllBranches = true
        /// Count changed lines with `git diff --shortstat`.
        public var lineCounts = true
        public var maxComparisons = 40
        /// Count untracked files in each worktree's status. Off, status skips the search for them,
        /// which in a big checkout without the untracked cache is most of its time.
        public var untrackedFiles = true
        /// List every remote-tracking branch. Off, a snapshot reads only the primary remote branch,
        /// which on a remote with many thousands of branches saves reading and parsing megabytes of
        /// refs on every refresh; `remoteBranches()` lists them on demand.
        public var remoteBranches = true
        /// Worktrees whose status may write the index. Status normally doesn't (see `GitRunner.run`),
        /// so the untracked cache and file system monitor position it stores go stale unless
        /// something else rewrites the index; letting status write it now and then keeps them fresh.
        public var writeIndexIn: Set<String> = []
        /// Worktrees as an earlier snapshot read them, by path, to keep instead of reading their
        /// status again: after a pull, those it didn't move. Used only while the worktree's HEAD
        /// and branch are still the same.
        public var reuseWorktrees: [String: WorktreeInfo] = [:]

        public init(compareAllBranches: Bool = true, lineCounts: Bool = true, maxComparisons: Int = 40,
                    untrackedFiles: Bool = true, remoteBranches: Bool = true) {
            self.compareAllBranches = compareAllBranches
            self.lineCounts = lineCounts
            self.maxComparisons = maxComparisons
            self.untrackedFiles = untrackedFiles
            self.remoteBranches = remoteBranches
        }
    }

    /// How far a snapshot has got, for showing while it runs.
    public struct SnapshotProgress: Sendable, Hashable {
        /// The current step, e.g. "status 3/7" or "compare 12/40".
        public var step: String
        /// Worktrees whose status hasn't been read yet.
        public var pendingWorktrees: Set<String>
    }

    /// Reads remote, mode, worktrees and branches. Comparisons with the primary branch come from
    /// `cache` when neither commit changed since an earlier snapshot. `progress` is awaited after
    /// each step, so reports arrive in order.
    public func snapshot(options: SnapshotOptions = SnapshotOptions(), cache: ComparisonCache? = nil,
                         progress: (@Sendable (SnapshotProgress) async -> Void)? = nil) async throws -> RepoSnapshot {
        let cache = cache ?? ComparisonCache()
        let remoteName = try await primaryRemoteName()
        let remoteURL: String? = if let remoteName {
            await git.outputIfSuccess(["remote", "get-url", remoteName], in: url)
        } else { nil }

        let remoteRefs = "refs/remotes/\(remoteName ?? "origin")"
        let remoteHead = await remoteHeadBranch(remote: remoteName)
        // Without the full list, just the primary branch (or the usual candidates for it).
        let remotePatterns = options.remoteBranches ? [remoteRefs]
            : (remoteHead.map { [$0] } ?? Self.primaryCandidates).map { "\(remoteRefs)/\($0)" }
        let refsOutput = try await git.output(
            ["for-each-ref", "--format=\(GitParsers.refFormat)", "refs/heads"] + remotePatterns,
            in: url
        )
        let refs = GitParsers.parseRefs(refsOutput)
        let primary = remoteHead ?? primaryBranch(remote: remoteName, refs: refs)
        let mode = await checkoutMode(remote: remoteName)
        let primaryRef = remoteName.flatMap { r in primary.map { "\(r)/\($0)" } }
        let hasPrimaryRef = primaryRef.map { p in refs.contains { $0.refname == "refs/remotes/\(p)" } } ?? false
        // Compare against the remote primary branch, or the local one when there is no remote copy.
        let hasLocalPrimary = primary.map { p in refs.contains { $0.refname == "refs/heads/\(p)" } } ?? false
        let compareTarget = hasPrimaryRef ? primaryRef : (hasLocalPrimary ? primary : nil)
        let compareRef = hasPrimaryRef ? primaryRef.map { "refs/remotes/\($0)" } : primary.map { "refs/heads/\($0)" }
        let target: CompareTarget? = compareTarget.flatMap { name in
            refs.first { $0.refname == compareRef }.map { CompareTarget(ref: name, sha: $0.commit.sha) }
        }

        // Worktrees, each with status and diff stats.
        let worktreeRecords = GitParsers.parseWorktrees(
            try await git.output(["worktree", "list", "--porcelain"], in: url)
        ).filter { !$0.isBare }
        var pending = Set(worktreeRecords.map(\.path))
        await progress?(SnapshotProgress(step: "status 0/\(worktreeRecords.count)", pendingWorktrees: pending))
        let worktrees = try await withThrowingTaskGroup(of: (Int, WorktreeInfo).self) { group in
            for (index, record) in worktreeRecords.enumerated() {
                if let earlier = options.reuseWorktrees[record.path], earlier.head == record.head,
                   earlier.branch == record.branch, earlier.isPrunable == record.isPrunable {
                    var info = earlier
                    info.isMain = index == 0
                    info.isLocked = record.isLocked
                    group.addTask {
                        // Usually from the cache; recomputed if the primary branch moved since.
                        if let target, !record.head.isEmpty {
                            let versus = await comparison(of: record.head, to: target, diff: options.lineCounts, cache: cache)
                            info.versusPrimary = versus.count
                            info.committedDiff = versus.diff ?? .zero
                        }
                        return (index, info)
                    }
                    continue
                }
                group.addTask {
                    (index, await worktreeInfo(record, isMain: index == 0, compareTo: target,
                                               lineCounts: options.lineCounts, untrackedFiles: options.untrackedFiles,
                                               writeIndex: options.writeIndexIn.contains(record.path), cache: cache))
                }
            }
            var results: [(Int, WorktreeInfo)] = []
            for try await item in group {
                results.append(item)
                pending.remove(item.1.path)
                await progress?(SnapshotProgress(step: "status \(results.count)/\(worktreeRecords.count)", pendingWorktrees: pending))
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // Local branches.
        let remotePrefix = "refs/remotes/\(remoteName ?? "origin")/"
        var branches = refs.filter { $0.refname.hasPrefix("refs/heads/") }.map { ref in
            BranchInfo(
                name: String(ref.refname.dropFirst("refs/heads/".count)),
                commit: ref.commit,
                upstream: ref.upstream,
                upstreamGone: ref.track == "gone",
                tracking: ref.upstream == nil ? nil : GitParsers.parseTrack(ref.track),
                versusPrimary: nil,
                committedDiff: nil,
                worktreePath: ref.worktreePath
            )
        }
        // Remote branches (excluding the symbolic HEAD), unless only the primary one was read.
        var remoteBranches = !options.remoteBranches ? [] : refs.filter { $0.refname.hasPrefix(remotePrefix) && !$0.isSymref }.map { ref in
            RemoteBranchInfo(
                name: String(ref.refname.dropFirst(remotePrefix.count)),
                remote: remoteName ?? "origin",
                commit: ref.commit,
                versusPrimary: nil
            )
        }

        // Ahead/behind vs primary, most relevant branches first, capped.
        if let target {
            branches.sort { lhs, rhs in
                if (lhs.worktreePath != nil) != (rhs.worktreePath != nil) { return lhs.worktreePath != nil }
                return lhs.commit.date > rhs.commit.date
            }
            remoteBranches.sort { $0.commit.date > $1.commit.date }
            let limit = options.compareAllBranches ? options.maxComparisons : 0
            let localTargets = Set(branches.prefix(limit).map(\.name))
                .union(branches.filter { $0.worktreePath != nil }.map(\.name))
            let remoteTargets = Set(remoteBranches.prefix(max(0, limit - localTargets.count)).map(\.name))
            await withTaskGroup(of: Void.self) { group in
                // Bounded fan-out so a repo with many branches doesn't spawn dozens of processes at once.
                var jobs: [@Sendable () async -> Void] = []
                for i in branches.indices {
                    let branch = branches[i]
                    // Branches without a worktree also get a diff stat, like worktrees have.
                    let diff = options.lineCounts && branch.worktreePath == nil
                    guard localTargets.contains(branch.name) else { continue }
                    jobs.append { _ = await comparison(of: branch.commit.sha, to: target, diff: diff, cache: cache) }
                }
                for branch in remoteBranches where remoteTargets.contains(branch.name) {
                    jobs.append { _ = await comparison(of: branch.commit.sha, to: target, diff: false, cache: cache) }
                }
                var iterator = jobs.makeIterator()
                for _ in 0..<8 { if let job = iterator.next() { group.addTask(operation: job) } }
                var done = 0
                for await _ in group {
                    if let job = iterator.next() { group.addTask(operation: job) }
                    done += 1
                    await progress?(SnapshotProgress(step: "compare \(done)/\(jobs.count)", pendingWorktrees: []))
                }
            }
            // Fill in from the cache, which also holds comparisons made on demand (`comparison`).
            for i in branches.indices {
                let entry = await cache.entry(branches[i].commit.sha, target)
                branches[i].versusPrimary = entry?.count
                branches[i].committedDiff = branches[i].worktreePath == nil && options.lineCounts ? entry?.diff : nil
            }
            for i in remoteBranches.indices where remoteTargets.contains(remoteBranches[i].name) {
                remoteBranches[i].versusPrimary = await cache.entry(remoteBranches[i].commit.sha, target)?.count
            }
        }
        await cache.endPass()

        return RepoSnapshot(
            remoteName: remoteName,
            remoteURL: remoteURL,
            primaryBranch: primary,
            baseRef: compareTarget,
            baseSHA: target?.sha,
            mode: mode.mode,
            partialCloneFilter: mode.filter,
            worktrees: worktrees,
            branches: branches,
            remoteBranches: remoteBranches,
            remoteBranchesListed: options.remoteBranches,
            lastFetchDate: await lastFetchDate()
        )
    }

    /// Every remote-tracking branch of `remote`, newest commit first, for when a snapshot left them
    /// out (`SnapshotOptions.remoteBranches`). Reads only what the list shows.
    public func remoteBranches(remote: String) async throws -> [RemoteBranchInfo] {
        let prefix = "refs/remotes/\(remote)/"
        let format = ["%(refname)", "%(objectname)", "%(subject)", "%(authorname)", "%(committerdate:unix)", "%(symref)"]
            .joined(separator: "%00")
        let output = try await git.output(["for-each-ref", "--format=\(format)", "--sort=-committerdate", prefix], in: url,
                                          timeout: .seconds(120))
        return output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, f[5].isEmpty, f[0].hasPrefix(prefix) else { return nil }
            let commit = CommitSummary(sha: f[1], subject: f[2], author: f[3], date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0))
            return RemoteBranchInfo(name: String(f[0].dropFirst(prefix.count)), remote: remote, commit: commit, versusPrimary: nil)
        }
    }

    private func primaryRemoteName() async throws -> String? {
        let remotes = try await git.output(["remote"], in: url).split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    private static let primaryCandidates = ["main", "master", "trunk", "develop"]

    /// The branch `<remote>/HEAD` points to, if it is set.
    private func remoteHeadBranch(remote: String?) async -> String? {
        guard let remote,
              let head = await git.outputIfSuccess(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], in: url),
              head.hasPrefix("\(remote)/") else { return nil }
        return String(head.dropFirst(remote.count + 1))
    }

    /// The primary branch when `<remote>/HEAD` isn't set, guessed from `refs`.
    private func primaryBranch(remote: String?, refs: [GitParsers.RefRecord]) -> String? {
        let names = Set(refs.map(\.refname))
        for candidate in Self.primaryCandidates {
            if names.contains("refs/remotes/\(remote ?? "origin")/\(candidate)") { return candidate }
        }
        // Single-branch clones may have exactly one remote-tracking branch.
        let remoteRefs = refs.filter { $0.refname.hasPrefix("refs/remotes/") && !$0.isSymref }
        if remoteRefs.count == 1, let only = remoteRefs.first?.refname.split(separator: "/").last {
            return String(only)
        }
        // No usable remote: fall back to a conventional local branch.
        for candidate in Self.primaryCandidates where names.contains("refs/heads/\(candidate)") {
            return candidate
        }
        return nil
    }

    public func checkoutMode(remote: String?) async -> (mode: CheckoutMode, filter: String?) {
        let shallow = await git.outputIfSuccess(["rev-parse", "--is-shallow-repository"], in: url) == "true"
        let filter = await git.outputIfSuccess(["config", "--get", "remote.\(remote ?? "origin").partialclonefilter"], in: url)
        if shallow { return (.shallow, filter) }
        if let filter, !filter.isEmpty { return (.blobless, filter) }
        return (.full, nil)
    }

    private func worktreeInfo(_ record: GitParsers.WorktreeRecord, isMain: Bool, compareTo target: CompareTarget?,
                              lineCounts: Bool, untrackedFiles: Bool, writeIndex: Bool,
                              cache: ComparisonCache?) async -> WorktreeInfo {
        let wtURL = URL(fileURLWithPath: record.path)
        var info = WorktreeInfo(
            path: record.path,
            head: record.head,
            branch: record.branch,
            isMain: isMain,
            isLocked: record.isLocked,
            isPrunable: record.isPrunable,
            status: WorkingTreeStatus(),
            tracking: nil,
            upstream: nil,
            versusPrimary: nil,
            committedDiff: .zero,
            uncommittedDiff: .zero
        )
        guard !record.isPrunable, FileManager.default.fileExists(atPath: record.path) else { return info }

        async let statusOutput = git.outputIfSuccess(
            ["status", "--porcelain=v2", "--branch"] + (untrackedFiles ? [] : ["--untracked-files=no"]), in: wtURL,
            optionalLocks: writeIndex)
        async let uncommitted: String? = lineCounts ? git.outputIfSuccess(["diff", "--shortstat", "HEAD"], in: wtURL) : nil
        async let versus: (count: AheadBehind?, diff: DiffStat?)? = if let target, !record.head.isEmpty {
            comparison(of: record.head, to: target, diff: lineCounts, cache: cache)
        } else { nil }

        if let statusOutput = await statusOutput {
            let status = GitParsers.parseStatus(statusOutput)
            info.status = status.status
            info.status.untrackedCounted = untrackedFiles
            info.upstream = status.upstream
            info.tracking = status.aheadBehind
        }
        info.uncommittedDiff = GitParsers.parseShortStat(await uncommitted ?? "")
        let comparison = await versus
        info.versusPrimary = comparison?.count
        info.committedDiff = comparison?.diff ?? .zero
        return info
    }

    /// Ahead/behind of commit `sha` vs `target` and, with `diff`, its diff stat since the fork point.
    /// Reuses an earlier result for the same pair of commits from `cache`.
    public func comparison(of sha: String, to target: CompareTarget, diff: Bool,
                           cache: ComparisonCache?) async -> (count: AheadBehind?, diff: DiffStat?) {
        let cached = await cache?.entry(sha, target)
        async let countOutput: String? = cached?.count == nil
            ? git.outputIfSuccess(["rev-list", "--left-right", "--count", "\(sha)...\(target.sha)"], in: url) : nil
        async let diffOutput: String? = diff && cached?.diff == nil
            ? git.outputIfSuccess(["diff", "--shortstat", "\(target.sha)...\(sha)"], in: url) : nil
        let countText = await countOutput
        let diffText = await diffOutput
        let count = cached?.count ?? countText.flatMap(GitParsers.parseLeftRight)
        let stat = diff ? cached?.diff ?? diffText.map(GitParsers.parseShortStat) : nil
        await cache?.store(sha, target, count: count, diff: stat)
        return (count, stat)
    }

    /// Changed files and commits for one worktree. `primaryRef` is e.g. `origin/main`.
    ///
    /// `knownStatus` is the worktree's status from a snapshot taken just now. Each kind of change it
    /// rules out skips a scan of the working tree, which in a large checkout takes many seconds:
    /// no untracked files skips listing them, and no tracked changes means the working tree equals
    /// HEAD, so changes since the base are a diff of two commits.
    public func worktreeDetails(path: String, primaryRef: String?, knownStatus: WorkingTreeStatus? = nil,
                                maxCommits: Int = 50) async -> WorktreeDetails {
        let wt = URL(fileURLWithPath: path)
        let clean = knownStatus.map { !$0.hasTrackedChanges } ?? false
        let noUntracked = knownStatus.map { $0.untrackedCounted && $0.untracked == 0 } ?? false
        async let head = git.outputIfSuccess(["log", "-1", "--format=\(GitParsers.logFormat)", "HEAD"], in: wt)
        async let uncommitted: [FileChange] = clean ? [] : fileChanges(against: "HEAD", in: wt)
        async let untracked: String? = noUntracked ? nil
            : git.outputIfSuccess(["ls-files", "--others", "--exclude-standard", "-z"], in: wt)
        async let ahead = outputIf(primaryRef.map {
            ["log", "-n", String(maxCommits), "--format=\(GitParsers.logFormat)", "\($0)..HEAD"]
        }, in: wt)
        async let sinceBase: [FileChange] = if clean, let primaryRef {
            fileChanges(between: ["\(primaryRef)...HEAD"], in: wt)
        } else {
            changesSinceBase(primaryRef: primaryRef, in: wt)
        }

        let untrackedFiles = (await untracked ?? "").split(separator: "\0").map {
            FileChange(status: "?", path: String($0))
        }
        return WorktreeDetails(
            head: GitParsers.parseLog(await head ?? "").first,
            uncommitted: await uncommitted + untrackedFiles,
            commitsAhead: GitParsers.parseLog(await ahead ?? ""),
            changedSinceBase: await sinceBase
        )
    }

    /// Writes `path` as it is at `ref` to `destination` as a read-only file, replacing an older copy.
    /// The content goes through git's text output, so binary files are not preserved.
    public func exportFile(_ path: String, at ref: String, to destination: URL) async throws {
        let content = try await git.run(["show", "\(ref):\(path)"], in: url).stdout
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try Data(content.utf8).write(to: destination)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
    }

    /// Commits and changed files of a local branch that has no worktree, vs `primaryRef`.
    /// There is no working tree, so `uncommitted` is always empty.
    public func branchDetails(name: String, primaryRef: String?, maxCommits: Int = 50) async -> WorktreeDetails {
        let ref = "refs/heads/\(name)"
        async let head = git.outputIfSuccess(["log", "-1", "--format=\(GitParsers.logFormat)", ref], in: url)
        async let ahead = outputIf(primaryRef.map {
            ["log", "-n", String(maxCommits), "--format=\(GitParsers.logFormat)", "\($0)..\(ref)"]
        }, in: url)
        async let sinceBase: [FileChange] = if let primaryRef {
            fileChanges(between: ["\(primaryRef)...\(ref)"], in: url)
        } else { [] }
        return WorktreeDetails(
            head: GitParsers.parseLog(await head ?? "").first,
            uncommitted: [],
            commitsAhead: GitParsers.parseLog(await ahead ?? ""),
            changedSinceBase: await sinceBase
        )
    }

    /// The diff of one file in `scope`, using the same comparison as the Inspector's file lists.
    /// With `fullContext` the whole file comes back as one hunk, for folding in the UI.
    public func fileDiff(_ file: FileChange, scope: DiffScope, fullContext: Bool = true) async -> FileDiff {
        // Both paths for a rename, so git pairs them up again.
        let paths = ["--"] + [file.oldPath, file.path].compactMap { $0 }
        let context = fullContext ? ["-U1000000"] : []
        let output: String?
        switch scope {
        case let .uncommitted(worktree):
            let wt = URL(fileURLWithPath: worktree)
            if file.isUntracked {
                // Exits 1 when the files differ, which they always do here.
                output = try? await git.run(["diff", "--no-color", "--no-ext-diff", "--no-index"] + context + ["--", "/dev/null", file.path], in: wt, check: false).stdout
            } else {
                output = await rawDiff(["-M", "HEAD"] + context + paths, in: wt)
            }
        case let .sinceBase(worktree, primaryRef):
            let wt = URL(fileURLWithPath: worktree)
            if let base = await git.outputIfSuccess(["merge-base", "HEAD", primaryRef], in: wt) {
                output = await rawDiff(["-M", base] + context + paths, in: wt)
            } else {
                output = nil
            }
        case let .branch(name, primaryRef):
            output = await rawDiff(["-M", "\(primaryRef)...refs/heads/\(name)"] + context + paths, in: url)
        }
        return GitParsers.parseUnifiedDiff(output ?? "")
    }

    /// `git diff` stdout without trimming, which would drop a trailing blank context line.
    private func rawDiff(_ arguments: [String], in dir: URL) async -> String? {
        guard let result = try? await git.run(["diff", "--no-color", "--no-ext-diff"] + arguments, in: dir, timeout: .seconds(60), check: false),
              result.exitCode == 0 else { return nil }
        return result.stdout
    }

    /// Working tree vs the merge base of HEAD and the primary branch.
    private func changesSinceBase(primaryRef: String?, in wt: URL) async -> [FileChange] {
        guard let primaryRef,
              let base = await git.outputIfSuccess(["merge-base", "HEAD", primaryRef], in: wt) else { return [] }
        return await fileChanges(against: base, in: wt)
    }

    /// Working tree (including staged changes) vs `rev`.
    private func fileChanges(against rev: String, in wt: URL) async -> [FileChange] {
        await fileChanges(between: [rev], in: wt)
    }

    /// `git diff` of `revs`: one rev compares the working tree, `a...b` compares commits.
    private func fileChanges(between revs: [String], in dir: URL) async -> [FileChange] {
        // One run for statuses and line counts, so the working tree is compared only once.
        let output = await git.outputIfSuccess(["diff", "--raw", "--numstat", "-z", "-M"] + revs, in: dir)
        return GitParsers.parseRawNumstat(output ?? "")
    }

    private func outputIf(_ arguments: [String]?, in directory: URL) async -> String? {
        guard let arguments else { return nil }
        return await git.outputIfSuccess(arguments, in: directory)
    }

    public func commonGitDirectory() async -> URL? {
        guard let path = await git.outputIfSuccess(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: url) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func lastFetchDate() async -> Date? {
        guard let dir = await commonGitDirectory() else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("FETCH_HEAD").path)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - Fetch & fast-forward

    public struct FetchOptions: Sendable, Hashable {
        public var scope: FetchScope
        /// Download tags pointing into fetched history (git's default). False passes `--no-tags`.
        public var tags: Bool
        /// Let git run `gc --auto` after the fetch (its default). False passes `--no-auto-gc`, so a
        /// background fetch never starts repacking gigabytes; Clean Up does that when asked.
        public var autoGC: Bool
        /// Delete remote-tracking branches that are gone from the remote (`--prune`, all-branches
        /// fetches only; narrow fetches always drop those of local branches' upstreams).
        public var prune: Bool

        public init(scope: FetchScope = .all, tags: Bool = true, autoGC: Bool = true, prune: Bool = true) {
            self.scope = scope
            self.tags = tags
            self.autoGC = autoGC
            self.prune = prune
        }
    }

    /// Fetches the primary remote. Shallow and blobless checkouts keep their mode: a blob filter is
    /// stored in the remote config and reapplied by git, and a fetch into a shallow repo only adds
    /// the commits since the existing shallow boundary (use `convert(to: .shallow)` to trim again).
    public func fetch(remote: String? = nil, options: FetchOptions = FetchOptions()) async throws {
        var remote = remote
        if remote == nil { remote = try await primaryRemoteName() }
        guard let remote else { return }
        if await git.outputIfSuccess(["symbolic-ref", "refs/remotes/\(remote)/HEAD"], in: url) == nil {
            _ = try? await git.run(["remote", "set-head", remote, "--auto"], in: url, timeout: .seconds(60))
        }
        let flags = (options.tags ? [] : ["--no-tags"]) + (options.autoGC ? [] : ["--no-auto-gc"])
        if options.scope == .primaryAndLocal, let refspecs = try await narrowFetchRefspecs(remote: remote) {
            guard !refspecs.isEmpty else { return }
            try await git.run(["fetch", "--no-progress", "--stdin"] + flags + [remote], in: url, timeout: .seconds(600),
                              input: Data(refspecs.joined(separator: "\n").utf8))
        } else {
            // Explicit both ways: `fetch.prune` in the user's config would otherwise prune anyway.
            let prune = options.prune ? ["--prune"] : ["--no-prune"]
            try await git.run(["fetch"] + prune + ["--no-progress"] + flags + [remote], in: url, timeout: .seconds(600))
        }
    }

    /// Refspecs for the primary branch and the upstreams of local branches that still exist on
    /// `remote`. Remote-tracking branches of those that were deleted are removed, as `--prune` would.
    /// nil when the primary branch isn't known, so the caller fetches everything instead.
    private func narrowFetchRefspecs(remote: String) async throws -> [String]? {
        let trackingPrefix = "refs/remotes/\(remote)/"
        guard let head = await git.outputIfSuccess(["symbolic-ref", "refs/remotes/\(remote)/HEAD"], in: url),
              head.hasPrefix(trackingPrefix) else { return nil }
        // Remote branch -> local remote-tracking branch.
        var sources = ["refs/heads/" + head.dropFirst(trackingPrefix.count): head]
        let upstreams = try await git.output(
            ["for-each-ref", "--format=%(upstream:remotename)%09%(upstream:remoteref)%09%(upstream)", "refs/heads"], in: url)
        for line in upstreams.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 3, parts[0] == remote, parts[1].hasPrefix("refs/heads/"), parts[2].hasPrefix(trackingPrefix) else { continue }
            sources[parts[1]] = parts[2]
        }
        // The server filters by these names (protocol v2), so this stays small on repos with many branches.
        let listed = try await git.output(["ls-remote", "--heads", remote] + sources.keys.sorted(), in: url, timeout: .seconds(120))
        let existing = Set(listed.split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) })
        let gone = sources.filter { !existing.contains($0.key) }.map(\.value).sorted()
        if !gone.isEmpty {
            try await git.run(["update-ref", "--stdin"], in: url,
                              input: Data(gone.map { "delete \($0)\n" }.joined().utf8))
        }
        return sources.filter { existing.contains($0.key) }.map { "+\($0.key):\($0.value)" }.sorted()
    }

    /// Moves local tags to where the remote has them, overwriting the local copies.
    /// Fixes a fetch rejected with "would clobber existing tag" (see `GitError.clobberedTags`).
    public func updateTags(_ tags: [String], remote: String? = nil) async throws {
        var remote = remote
        if remote == nil { remote = try await primaryRemoteName() }
        guard let remote, !tags.isEmpty else { return }
        let refspecs = tags.map { "+refs/tags/\($0):refs/tags/\($0)" }
        try await git.run(["fetch", "--no-tags", "--no-progress", remote] + refspecs, in: url, timeout: .seconds(600))
    }

    public enum FastForwardOutcome: Sendable, Hashable {
        case updated(commits: Int)
        case upToDate
        case skipped(String)
    }

    /// Fast-forwards a worktree's checked-out branch to its upstream. Never merges or rebases.
    public func fastForward(worktree path: String) async throws -> FastForwardOutcome {
        let status = GitParsers.parseStatus(
            try await git.output(["status", "--porcelain=v2", "--branch"], in: URL(fileURLWithPath: path))
        )
        return try await fastForward(worktree: path, branch: status.branch, upstream: status.upstream,
                                     tracking: status.aheadBehind, status: status.status)
    }

    /// Like `fastForward(worktree:)`, but decides from `worktree` as a recent snapshot saw it instead
    /// of reading its status again, which is slow in large checkouts. Worktrees the snapshot rules
    /// out (`outcomeWithoutMerge`) cost no git run at all. One it would move has its status read
    /// again first, so edits made since the snapshot still skip it.
    public func fastForward(worktree: WorktreeInfo) async throws -> FastForwardOutcome {
        if let outcome = worktree.outcomeWithoutMerge { return outcome }
        return try await fastForward(worktree: worktree.path)
    }

    private func fastForward(worktree path: String, branch: String?, upstream: String?, tracking: AheadBehind?,
                             status: WorkingTreeStatus) async throws -> FastForwardOutcome {
        if let outcome = Self.outcomeWithoutMerge(branch: branch, upstream: upstream, tracking: tracking, status: status) {
            return outcome
        }
        try await git.run(["merge", "--ff-only", "--no-stat", "@{upstream}"], in: URL(fileURLWithPath: path), timeout: .seconds(300))
        return .updated(commits: tracking?.behind ?? 0)
    }

    /// What fast-forwarding comes to when it needs no merge; nil when it would merge.
    static func outcomeWithoutMerge(branch: String?, upstream: String?, tracking: AheadBehind?,
                                    status: WorkingTreeStatus) -> FastForwardOutcome? {
        guard branch != nil else { return .skipped("detached HEAD") }
        guard upstream != nil, let ab = tracking else { return .skipped("no upstream") }
        if ab.behind == 0 { return .upToDate }
        if ab.ahead > 0 { return .skipped("diverged (\(ab.ahead) local commits)") }
        if status.hasTrackedChanges { return .skipped("uncommitted changes") }
        return nil
    }

    /// Moves a branch that is not checked out anywhere to its upstream, if that is a fast-forward.
    public func fastForward(branch: BranchInfo) async throws -> FastForwardOutcome {
        guard branch.worktreePath == nil else { return .skipped("checked out") }
        guard let upstream = branch.upstream, let tracking = branch.tracking else { return .skipped("no upstream") }
        if tracking.behind == 0 { return .upToDate }
        if tracking.ahead > 0 { return .skipped("diverged") }
        let upstreamSHA = try await git.output(["rev-parse", "--verify", "\(upstream)^{commit}"], in: url)
        try await git.run(["update-ref", "-m", "grove: fast-forward", "refs/heads/\(branch.name)", upstreamSHA, branch.commit.sha], in: url)
        return .updated(commits: tracking.behind)
    }

    // MARK: - Worktrees

    /// Creates a worktree for an existing local branch, or for a remote branch (creating a tracking branch).
    public func addWorktree(branch: String, at path: URL) async throws {
        try await git.run(["worktree", "add", path.path, branch], in: url, timeout: .seconds(600))
    }

    /// Current working-tree status of a worktree, read fresh (not from a snapshot).
    public func workingTreeStatus(path: String) async throws -> WorkingTreeStatus {
        GitParsers.parseStatus(
            try await git.output(["status", "--porcelain=v2", "--branch"], in: URL(fileURLWithPath: path))
        ).status
    }

    /// Deletes a linked worktree's folder and git's record of it; the branch is kept.
    /// Without `discardingChanges`, git refuses when there are uncommitted or untracked files.
    public func removeWorktree(path: String, discardingChanges: Bool) async throws {
        let args = ["worktree", "remove"] + (discardingChanges ? ["--force"] : []) + [path]
        try await git.run(args, in: url, timeout: .seconds(120))
    }

    // MARK: - Branches

    /// Commits reachable from `branch` and from no other ref (branch, tag, remote branch, HEAD,
    /// stash): the ones that deleting the branch would lose.
    public func commitsOnlyOn(branch: String) async throws -> Int {
        let ref = "refs/heads/\(branch)"
        let count = try await git.output(["rev-list", "--count", ref, "--not", "--exclude=\(ref)", "--all"], in: url)
        return Int(count) ?? 0
    }

    /// Deletes a local branch even if it isn't merged (the caller has confirmed). Its remote branch is kept.
    public func deleteBranch(_ branch: String) async throws {
        try await git.run(["branch", "-D", branch], in: url)
    }

    /// Forgets worktrees whose folders no longer exist.
    public func pruneWorktrees() async throws {
        try await git.run(["worktree", "prune"], in: url)
    }

    // MARK: - Clone

    public static func clone(
        _ source: String,
        to destination: URL,
        mode: CheckoutMode,
        depth: Int = 1,
        git: GitRunner,
        progress: (@Sendable (GitParsers.Progress) -> Void)? = nil
    ) async throws {
        var args = ["clone", "--progress"]
        switch mode {
        case .full: break
        case .shallow: args += ["--depth", String(max(1, depth)), "--single-branch"]
        case .blobless: args += ["--filter=blob:none"]
        }
        args += [source, destination.path]

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lineBuffer = LineSplitter()
        try await git.run(args, in: parent, timeout: .seconds(3600)) { chunk in
            guard let progress else { return }
            for line in lineBuffer.feed(chunk) {
                if let p = GitParsers.parseProgress(line) { progress(p) }
            }
        }
    }

    // MARK: - Mode conversion

    /// Converts the checkout between full, shallow, and blobless. Converting to `.shallow` also
    /// restricts fetching to the primary branch; calling it on a shallow repo re-trims history.
    public func convert(to target: CheckoutMode, depth: Int = 1) async throws {
        guard let remote = try await primaryRemoteName() else {
            throw GitError(arguments: ["convert"], exitCode: 1, stderr: "repository has no remote")
        }
        let current = await checkoutMode(remote: remote)
        let wildcardRefspec = "+refs/heads/*:refs/remotes/\(remote)/*"
        let long: Duration = .seconds(3600)

        switch target {
        case .full:
            try await git.run(["config", "--replace-all", "remote.\(remote).fetch", wildcardRefspec], in: url)
            if current.filter != nil {
                try await git.run(["config", "--unset", "remote.\(remote).partialclonefilter"], in: url)
            }
            var args = ["fetch", "--prune", "--no-progress"]
            if current.mode == .shallow { args.append("--unshallow") }
            // A refetch without a filter downloads every object the filter had omitted.
            if current.filter != nil { args.append("--refetch") }
            try await git.run(args + [remote], in: url, timeout: long)
            _ = try? await git.run(["remote", "set-head", remote, "--auto"], in: url)

        case .blobless:
            try await git.run(["config", "core.repositoryformatversion", "1"], in: url)
            try await git.run(["config", "extensions.partialclone", remote], in: url)
            try await git.run(["config", "remote.\(remote).promisor", "true"], in: url)
            try await git.run(["config", "remote.\(remote).partialclonefilter", "blob:none"], in: url)
            if current.mode == .shallow {
                try await git.run(["config", "--replace-all", "remote.\(remote).fetch", wildcardRefspec], in: url)
                try await git.run(["fetch", "--prune", "--no-progress", "--unshallow", "--filter=blob:none", remote], in: url, timeout: long)
                _ = try? await git.run(["remote", "set-head", remote, "--auto"], in: url)
            }
            // Filter locally instead of refetching: a fetch into a partial clone moves local objects
            // referenced by the fetched ones into a promisor pack (which repack never filters), and
            // how many history blobs that sweeps up varies from run to run.
            try await dropBlobsExceptCheckedOut()

        case .shallow:
            let snapshot = try await snapshot(options: SnapshotOptions(compareAllBranches: false, lineCounts: false))
            guard let primary = snapshot.primaryBranch else {
                throw GitError(arguments: ["convert"], exitCode: 1, stderr: "cannot determine the primary branch")
            }
            let primaryRemoteRef = "refs/remotes/\(remote)/\(primary)"
            try await git.run(
                ["config", "--replace-all", "remote.\(remote).fetch", "+refs/heads/\(primary):\(primaryRemoteRef)"],
                in: url
            )
            if current.filter != nil {
                try await git.run(["config", "--unset", "remote.\(remote).partialclonefilter"], in: url)
            }
            // Drop the other remote-tracking branches so their history can be pruned.
            for branch in snapshot.remoteBranches where branch.name != primary {
                try await git.run(["update-ref", "-d", "refs/remotes/\(remote)/\(branch.name)"], in: url)
            }

            // Local primary branch: remember whether it can follow the new tip (no local commits).
            let localPrimary = snapshot.branches.first { $0.name == primary }
            let canMovePrimary = localPrimary.map { ($0.tracking?.ahead ?? 1) == 0 } ?? false

            try await git.run(["fetch", "--prune", "--no-progress", "--depth", String(max(1, depth)), remote, primary], in: url, timeout: long)
            try await git.run(["update-ref", primaryRemoteRef, "FETCH_HEAD"], in: url)

            if let localPrimary, canMovePrimary {
                if let wt = localPrimary.worktreePath {
                    let status = GitParsers.parseStatus(
                        try await git.output(["status", "--porcelain=v2"], in: URL(fileURLWithPath: wt))
                    )
                    if !status.status.hasTrackedChanges {
                        // ff-merge cannot prove ancestry across the new shallow boundary; --keep is safe here
                        // because the branch had no commits of its own and the tree is clean.
                        try await git.run(["reset", "--keep", "-q", primaryRemoteRef], in: URL(fileURLWithPath: wt))
                    }
                } else {
                    try await git.run(["update-ref", "refs/heads/\(primary)", primaryRemoteRef], in: url)
                }
            }
            try await expireReflogs()
            try await git.run(["gc", "--prune=now", "--quiet"], in: url, timeout: long)
        }
    }

    /// Removes all blobs except those in the worktrees' indexes (the checked-out and staged files)
    /// and marks the remaining packs as promisor packs, so missing blobs are fetched on demand.
    /// Requires the partial clone config to be set already.
    private func dropBlobsExceptCheckedOut() async throws {
        guard let gitDir = await commonGitDirectory() else {
            throw GitError(arguments: ["rev-parse", "--git-common-dir"], exitCode: 1, stderr: "git directory not found")
        }
        let packDir = gitDir.appendingPathComponent("objects/pack")
        let long: Duration = .seconds(3600)

        // Collect blob ids from every worktree's index (gitlinks are commits in other repos).
        let worktrees = GitParsers.parseWorktrees(try await git.output(["worktree", "list", "--porcelain"], in: url))
            .filter { !$0.isBare && !$0.isPrunable }
        var blobs = Set<String>()
        for wt in worktrees {
            let staged = try await git.run(["ls-files", "--stage", "-z"], in: URL(fileURLWithPath: wt.path)).stdout
            for entry in staged.split(separator: "\0") {
                let fields = entry.split(separator: " ", maxSplits: 2)
                if fields.count == 3, fields[0] != "160000" { blobs.insert(String(fields[1])) }
            }
        }

        // Pack them separately and protect that pack with .keep while the rest is filtered.
        try await git.run(["repack", "-a", "-d", "-q"], in: url, timeout: long)
        var keep: URL?
        if !blobs.isEmpty {
            let name = try await git.run(
                ["pack-objects", "-q", packDir.appendingPathComponent("pack").path],
                in: url, timeout: long, input: Data(blobs.sorted().joined(separator: "\n").utf8)
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            keep = packDir.appendingPathComponent("pack-\(name).keep")
            FileManager.default.createFile(atPath: keep!.path, contents: nil)
        }
        defer { if let keep { try? FileManager.default.removeItem(at: keep) } }

        try await expireReflogs()
        // `repack --filter` writes the filtered-out objects to a separate pack; send it to a scratch
        // directory and delete it.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("grove-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await git.run(
            ["repack", "-a", "-d", "-q", "--filter=blob:none", "--filter-to=\(scratch.appendingPathComponent("pack").path)"],
            in: url, timeout: long
        )

        // Every remaining object now counts as coming from the promisor remote, which is what lets
        // the missing blobs be absent.
        for file in try FileManager.default.contentsOfDirectory(atPath: packDir.path) where file.hasSuffix(".pack") {
            let marker = packDir.appendingPathComponent(String(file.dropLast(".pack".count)) + ".promisor")
            if !FileManager.default.fileExists(atPath: marker.path) {
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            }
        }
        _ = try? await git.run(["prune", "--expire=now"], in: url, timeout: long)
    }

    private func expireReflogs() async throws {
        try await git.run(["reflog", "expire", "--expire=now", "--all"], in: url, timeout: .seconds(600))
    }
}

/// Splits git's progress stream, which uses `\r` for in-place updates, into lines.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func feed(_ chunk: String) -> [String] {
        lock.withLock {
            pending += chunk
            var parts = pending.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
                .map(String.init)
            pending = parts.popLast() ?? ""
            return parts.filter { !$0.isEmpty }
        }
    }
}

extension WorktreeInfo {
    /// What fast-forwarding this worktree comes to as this snapshot saw it, when that needs no
    /// merge; nil when it would merge (and its status is then read again first).
    public var outcomeWithoutMerge: GitRepository.FastForwardOutcome? {
        GitRepository.outcomeWithoutMerge(branch: branch, upstream: upstream, tracking: tracking, status: status)
    }
}
