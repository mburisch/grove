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

    /// Reads remote, mode, worktrees and branches. `maxComparisons` caps how many
    /// branches get an ahead/behind count against the primary branch.
    public func snapshot(maxComparisons: Int = 40) async throws -> RepoSnapshot {
        let remoteName = try await primaryRemoteName()
        let remoteURL: String? = if let remoteName {
            await git.outputIfSuccess(["remote", "get-url", remoteName], in: url)
        } else { nil }

        let refsOutput = try await git.output(
            ["for-each-ref", "--format=\(GitParsers.refFormat)", "refs/heads", "refs/remotes/\(remoteName ?? "origin")"],
            in: url
        )
        let refs = GitParsers.parseRefs(refsOutput)
        let primary = await primaryBranch(remote: remoteName, refs: refs)
        let mode = await checkoutMode(remote: remoteName)
        let primaryRef = remoteName.flatMap { r in primary.map { "\(r)/\($0)" } }
        let hasPrimaryRef = primaryRef.map { p in refs.contains { $0.refname == "refs/remotes/\(p)" } } ?? false
        // Compare against the remote primary branch, or the local one when there is no remote copy.
        let hasLocalPrimary = primary.map { p in refs.contains { $0.refname == "refs/heads/\(p)" } } ?? false
        let compareTarget = hasPrimaryRef ? primaryRef : (hasLocalPrimary ? primary : nil)

        // Worktrees, each with status and diff stats.
        let worktreeRecords = GitParsers.parseWorktrees(
            try await git.output(["worktree", "list", "--porcelain"], in: url)
        ).filter { !$0.isBare }
        let worktrees = try await withThrowingTaskGroup(of: (Int, WorktreeInfo).self) { group in
            for (index, record) in worktreeRecords.enumerated() {
                group.addTask {
                    (index, await worktreeInfo(record, isMain: index == 0, compareTo: compareTarget))
                }
            }
            var results: [(Int, WorktreeInfo)] = []
            for try await item in group { results.append(item) }
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
        // Remote branches (excluding the symbolic HEAD).
        var remoteBranches = refs.filter { $0.refname.hasPrefix(remotePrefix) && !$0.isSymref }.map { ref in
            RemoteBranchInfo(
                name: String(ref.refname.dropFirst(remotePrefix.count)),
                remote: remoteName ?? "origin",
                commit: ref.commit,
                versusPrimary: nil
            )
        }

        // Ahead/behind vs primary, most relevant branches first, capped.
        if let compareTarget {
            branches.sort { lhs, rhs in
                if (lhs.worktreePath != nil) != (rhs.worktreePath != nil) { return lhs.worktreePath != nil }
                return lhs.commit.date > rhs.commit.date
            }
            remoteBranches.sort { $0.commit.date > $1.commit.date }
            let localTargets = branches.prefix(maxComparisons).map { "refs/heads/\($0.name)" }
            let remoteTargets = remoteBranches.prefix(max(0, maxComparisons - localTargets.count))
                .map { "\(remotePrefix)\($0.name)" }
            // Branches without a worktree also get a diff stat, like worktrees have.
            let diffTargets = Set(branches.prefix(maxComparisons).filter { $0.worktreePath == nil }
                .map { "refs/heads/\($0.name)" })
            let (counts, diffs) = await compare(localTargets + remoteTargets, to: compareTarget, diffing: diffTargets)
            for i in branches.indices {
                let ref = "refs/heads/\(branches[i].name)"
                branches[i].versusPrimary = counts[ref]
                branches[i].committedDiff = diffs[ref]
            }
            for i in remoteBranches.indices {
                remoteBranches[i].versusPrimary = counts["\(remotePrefix)\(remoteBranches[i].name)"]
            }
        }

        return RepoSnapshot(
            remoteName: remoteName,
            remoteURL: remoteURL,
            primaryBranch: primary,
            baseRef: compareTarget,
            mode: mode.mode,
            partialCloneFilter: mode.filter,
            worktrees: worktrees,
            branches: branches,
            remoteBranches: remoteBranches,
            lastFetchDate: await lastFetchDate()
        )
    }

    private func primaryRemoteName() async throws -> String? {
        let remotes = try await git.output(["remote"], in: url).split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    private func primaryBranch(remote: String?, refs: [GitParsers.RefRecord]) async -> String? {
        if let remote,
           let head = await git.outputIfSuccess(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], in: url),
           head.hasPrefix("\(remote)/") {
            return String(head.dropFirst(remote.count + 1))
        }
        let names = Set(refs.map(\.refname))
        for candidate in ["main", "master", "trunk", "develop"] {
            if names.contains("refs/remotes/\(remote ?? "origin")/\(candidate)") { return candidate }
        }
        // Single-branch clones may have exactly one remote-tracking branch.
        let remoteRefs = refs.filter { $0.refname.hasPrefix("refs/remotes/") && !$0.isSymref }
        if remoteRefs.count == 1, let only = remoteRefs.first?.refname.split(separator: "/").last {
            return String(only)
        }
        // No usable remote: fall back to a conventional local branch.
        for candidate in ["main", "master", "trunk", "develop"] where names.contains("refs/heads/\(candidate)") {
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

    private func worktreeInfo(_ record: GitParsers.WorktreeRecord, isMain: Bool, compareTo target: String?) async -> WorktreeInfo {
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

        async let statusOutput = git.outputIfSuccess(["status", "--porcelain=v2", "--branch"], in: wtURL)
        async let uncommitted = git.outputIfSuccess(["diff", "--shortstat", "HEAD"], in: wtURL)
        async let versus: String? = if let target {
            git.outputIfSuccess(["rev-list", "--left-right", "--count", "HEAD...\(target)"], in: wtURL)
        } else { nil }
        async let committed: String? = if let target {
            git.outputIfSuccess(["diff", "--shortstat", "\(target)...HEAD"], in: wtURL)
        } else { nil }

        if let statusOutput = await statusOutput {
            let status = GitParsers.parseStatus(statusOutput)
            info.status = status.status
            info.upstream = status.upstream
            info.tracking = status.aheadBehind
        }
        info.uncommittedDiff = GitParsers.parseShortStat(await uncommitted ?? "")
        info.versusPrimary = await versus.flatMap(GitParsers.parseLeftRight)
        info.committedDiff = GitParsers.parseShortStat(await committed ?? "")
        return info
    }

    /// Ahead/behind of each ref vs `target`, plus a diff stat since the fork point for the refs in `diffing`.
    private func compare(_ refs: [String], to target: String, diffing: Set<String> = []) async
        -> (counts: [String: AheadBehind], diffs: [String: DiffStat]) {
        await withTaskGroup(of: (String, AheadBehind?, DiffStat?).self) { group in
            // Bounded fan-out so a repo with many branches doesn't spawn dozens of processes at once.
            var iterator = refs.makeIterator()
            func addNext() {
                guard let ref = iterator.next() else { return }
                group.addTask {
                    async let out = git.outputIfSuccess(["rev-list", "--left-right", "--count", "\(ref)...\(target)"], in: url)
                    async let diff: String? = diffing.contains(ref)
                        ? git.outputIfSuccess(["diff", "--shortstat", "\(target)...\(ref)"], in: url) : nil
                    return (ref, await out.flatMap(GitParsers.parseLeftRight), await diff.map(GitParsers.parseShortStat))
                }
            }
            for _ in 0..<8 { addNext() }
            var counts: [String: AheadBehind] = [:]
            var diffs: [String: DiffStat] = [:]
            for await (ref, count, diff) in group {
                if let count { counts[ref] = count }
                if let diff { diffs[ref] = diff }
                addNext()
            }
            return (counts, diffs)
        }
    }

    /// Changed files and commits for one worktree. `primaryRef` is e.g. `origin/main`.
    public func worktreeDetails(path: String, primaryRef: String?, maxCommits: Int = 50) async -> WorktreeDetails {
        let wt = URL(fileURLWithPath: path)
        async let head = git.outputIfSuccess(["log", "-1", "--format=\(GitParsers.logFormat)", "HEAD"], in: wt)
        async let uncommitted = fileChanges(against: "HEAD", in: wt)
        async let untracked = git.outputIfSuccess(["ls-files", "--others", "--exclude-standard", "-z"], in: wt)
        async let ahead = outputIf(primaryRef.map {
            ["log", "-n", String(maxCommits), "--format=\(GitParsers.logFormat)", "\($0)..HEAD"]
        }, in: wt)
        async let sinceBase = changesSinceBase(primaryRef: primaryRef, in: wt)

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
        async let numstat = git.outputIfSuccess(["diff", "--numstat", "-z", "-M"] + revs, in: dir)
        async let nameStatus = git.outputIfSuccess(["diff", "--name-status", "-z", "-M"] + revs, in: dir)
        return GitParsers.parseFileChanges(numstat: await numstat ?? "", nameStatus: await nameStatus ?? "")
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

    /// Fetches the primary remote. Shallow and blobless checkouts keep their mode: a blob filter is
    /// stored in the remote config and reapplied by git, and a fetch into a shallow repo only adds
    /// the commits since the existing shallow boundary (use `convert(to: .shallow)` to trim again).
    public func fetch(remote: String? = nil) async throws {
        var remote = remote
        if remote == nil { remote = try await primaryRemoteName() }
        guard let remote else { return }
        try await git.run(["fetch", "--prune", "--no-progress", remote], in: url, timeout: .seconds(600))
        if await git.outputIfSuccess(["symbolic-ref", "refs/remotes/\(remote)/HEAD"], in: url) == nil {
            _ = try? await git.run(["remote", "set-head", remote, "--auto"], in: url, timeout: .seconds(60))
        }
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
        let wtURL = URL(fileURLWithPath: path)
        let status = GitParsers.parseStatus(
            try await git.output(["status", "--porcelain=v2", "--branch"], in: wtURL)
        )
        guard status.branch != nil else { return .skipped("detached HEAD") }
        guard status.upstream != nil, let ab = status.aheadBehind else { return .skipped("no upstream") }
        if ab.behind == 0 { return .upToDate }
        if ab.ahead > 0 { return .skipped("diverged (\(ab.ahead) local commits)") }
        if status.status.hasTrackedChanges { return .skipped("uncommitted changes") }
        try await git.run(["merge", "--ff-only", "--no-stat", "@{upstream}"], in: wtURL, timeout: .seconds(300))
        return .updated(commits: ab.behind)
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
            let snapshot = try await snapshot(maxComparisons: 0)
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
