import Foundation

/// How much of the remote's history and content a checkout holds.
public enum CheckoutMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// All history and all blobs.
    case full
    /// Truncated history of the primary branch only (`--depth --single-branch`).
    case shallow
    /// All commits and trees, blobs fetched on demand (`--filter=blob:none`).
    case blobless

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .full: "Full"
        case .shallow: "Shallow"
        case .blobless: "Blobless"
        }
    }
}

public struct AheadBehind: Sendable, Hashable, Codable {
    public var ahead: Int
    public var behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }

    public static let zero = AheadBehind(ahead: 0, behind: 0)
    public var isZero: Bool { ahead == 0 && behind == 0 }
}

public struct DiffStat: Sendable, Hashable {
    public var files: Int
    public var insertions: Int
    public var deletions: Int

    public init(files: Int, insertions: Int, deletions: Int) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }

    public static let zero = DiffStat(files: 0, insertions: 0, deletions: 0)
    public var isZero: Bool { files == 0 }
}

public struct WorkingTreeStatus: Sendable, Hashable {
    public var staged: Int = 0
    public var unstaged: Int = 0
    public var untracked: Int = 0
    public var conflicted: Int = 0

    public init(staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
    }

    /// Tracked modifications; untracked files alone do not block a fast-forward.
    public var hasTrackedChanges: Bool { staged + unstaged + conflicted > 0 }
    public var isClean: Bool { !hasTrackedChanges && untracked == 0 }
}

public struct CommitSummary: Sendable, Hashable {
    public var sha: String
    public var subject: String
    public var author: String
    public var date: Date
}

public struct BranchInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var commit: CommitSummary
    /// Upstream ref short name, e.g. `origin/main`.
    public var upstream: String?
    public var upstreamGone: Bool
    /// Ahead/behind relative to the upstream.
    public var tracking: AheadBehind?
    /// Ahead/behind relative to `origin/<primary>`; nil when not computed.
    public var versusPrimary: AheadBehind?
    /// Path of the worktree this branch is checked out in, if any.
    public var worktreePath: String?

    public var id: String { name }
}

public struct RemoteBranchInfo: Sendable, Hashable, Identifiable {
    /// Short name without the remote prefix, e.g. `feature/x`.
    public var name: String
    public var remote: String
    public var commit: CommitSummary
    public var versusPrimary: AheadBehind?

    public var id: String { "\(remote)/\(name)" }
}

public struct WorktreeInfo: Sendable, Hashable, Identifiable {
    public var path: String
    public var head: String
    /// Branch short name, or nil when detached.
    public var branch: String?
    public var isMain: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    public var status: WorkingTreeStatus
    /// Ahead/behind of HEAD vs its upstream.
    public var tracking: AheadBehind?
    public var upstream: String?
    /// Ahead/behind of HEAD vs `origin/<primary>`.
    public var versusPrimary: AheadBehind?
    /// Committed changes on HEAD since it diverged from `origin/<primary>`.
    public var committedDiff: DiffStat
    /// Uncommitted changes vs HEAD.
    public var uncommittedDiff: DiffStat

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// A point-in-time read of a repository's state.
public struct RepoSnapshot: Sendable, Hashable {
    public var remoteName: String?
    public var remoteURL: String?
    public var primaryBranch: String?
    public var mode: CheckoutMode
    public var partialCloneFilter: String?
    public var worktrees: [WorktreeInfo]
    public var branches: [BranchInfo]
    public var remoteBranches: [RemoteBranchInfo]
    public var lastFetchDate: Date?

    public var mainWorktree: WorktreeInfo? { worktrees.first(where: \.isMain) ?? worktrees.first }

    public var primaryRemoteRef: String? {
        guard let remoteName, let primaryBranch else { return nil }
        return "\(remoteName)/\(primaryBranch)"
    }

    public var gitHub: GitHubRepo? { remoteURL.flatMap(GitHubRepo.init(remoteURL:)) }
}
