import Foundation

public struct ScanRoot: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var depth: Int

    public init(path: String, depth: Int = 2) {
        self.path = path
        self.depth = depth
    }

    public var id: String { path }
}

/// How much work Grove does to keep a repository current. Large repositories get cheaper defaults.
public enum RepoProfile: String, Codable, Sendable, CaseIterable {
    case normal, large

    /// Repositories whose object storage is at least this big are treated as large.
    public static let largeStorageBytes: Int64 = 2 << 30

    public static func detect(storageBytes: Int64) -> RepoProfile {
        storageBytes >= largeStorageBytes ? .large : .normal
    }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .large: "Large"
        }
    }
}

/// Which branches a fetch downloads.
public enum FetchScope: String, Codable, Sendable, CaseIterable {
    /// Every branch on the remote, pruning deleted ones.
    case all
    /// The primary branch and the upstreams of local branches.
    case primaryAndLocal
}

/// Per-repository settings, keyed by path in `AppConfig.repoSettings`. A nil field follows the profile.
public struct RepoSettings: Codable, Sendable, Hashable {
    /// Minutes between automatic fetches; nil uses the profile's default, 0 disables.
    public var fetchIntervalMinutes: Int?
    /// Depth used when trimming a shallow checkout.
    public var shallowDepth: Int?
    /// nil = chosen from the repository's size.
    public var profile: RepoProfile?
    public var fetchScope: FetchScope?
    public var fetchTags: Bool?
    /// Compare every recent branch with the primary branch, not just those checked out in a worktree.
    public var compareAllBranches: Bool?
    /// Count changed lines (`git diff --shortstat`) for worktrees and branches.
    public var lineCounts: Bool?

    public init(fetchIntervalMinutes: Int? = nil, shallowDepth: Int? = nil) {
        self.fetchIntervalMinutes = fetchIntervalMinutes
        self.shallowDepth = shallowDepth
    }

    /// True when any setting differs from the profile's defaults.
    public var hasOverrides: Bool {
        fetchIntervalMinutes != nil || fetchScope != nil || fetchTags != nil || compareAllBranches != nil || lineCounts != nil
    }

    /// Follows `profile` (nil = by size) with no individual overrides.
    public mutating func applyDefaults(_ profile: RepoProfile?) {
        self.profile = profile
        fetchIntervalMinutes = nil
        fetchScope = nil
        fetchTags = nil
        compareAllBranches = nil
        lineCounts = nil
    }
}

/// A repository's settings with every default filled in.
public struct EffectiveRepoSettings: Sendable, Hashable {
    public var profile: RepoProfile
    public var fetchIntervalMinutes: Int
    public var fetchScope: FetchScope
    public var fetchTags: Bool
    public var compareAllBranches: Bool
    public var lineCounts: Bool

    /// The defaults for `profile`. Large repositories fetch at most hourly, and only when
    /// automatic fetching is on at all.
    public static func defaults(_ profile: RepoProfile, defaultFetchIntervalMinutes: Int) -> EffectiveRepoSettings {
        switch profile {
        case .normal:
            EffectiveRepoSettings(profile: profile, fetchIntervalMinutes: defaultFetchIntervalMinutes, fetchScope: .all,
                                  fetchTags: true, compareAllBranches: true, lineCounts: true)
        case .large:
            EffectiveRepoSettings(profile: profile,
                                  fetchIntervalMinutes: defaultFetchIntervalMinutes > 0 ? max(defaultFetchIntervalMinutes, 60) : 0,
                                  fetchScope: .primaryAndLocal, fetchTags: false, compareAllBranches: false, lineCounts: false)
        }
    }

    public var fetchOptions: GitRepository.FetchOptions { .init(scope: fetchScope, tags: fetchTags) }
    public var snapshotOptions: GitRepository.SnapshotOptions {
        .init(compareAllBranches: compareAllBranches, lineCounts: lineCounts)
    }
}

public struct Launcher: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        /// Open the folder with an application, by bundle identifier.
        case app(bundleID: String)
        /// Run a shell command; `{path}` is replaced with the quoted folder path.
        case command(String)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
    }

    public static let defaults: [Launcher] = [
        Launcher(name: "Cursor", kind: .app(bundleID: "com.todesktop.230313mzl4w4u92")),
        Launcher(name: "VS Code", kind: .app(bundleID: "com.microsoft.VSCode")),
        Launcher(name: "Zed", kind: .app(bundleID: "dev.zed.Zed")),
        Launcher(name: "Xcode", kind: .app(bundleID: "com.apple.dt.Xcode")),
        Launcher(name: "Ghostty", kind: .app(bundleID: "com.mitchellh.ghostty")),
        Launcher(name: "iTerm", kind: .app(bundleID: "com.googlecode.iterm2")),
        Launcher(name: "Terminal", kind: .app(bundleID: "com.apple.Terminal")),
        Launcher(name: "Finder", kind: .app(bundleID: "com.apple.finder")),
    ]

    /// Expands a command template, shell-quoting the path.
    public static func expand(_ template: String, path: String) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return template.contains("{path}")
            ? template.replacingOccurrences(of: "{path}", with: quoted)
            : "\(template) \(quoted)"
    }
}

public struct AppConfig: Codable, Sendable, Hashable {
    /// Repositories added explicitly.
    public var repositories: [String] = []
    /// Folders scanned for repositories.
    public var scanRoots: [ScanRoot] = []
    /// Scanned repositories the user removed from the list.
    public var excluded: [String] = []
    public var repoSettings: [String: RepoSettings] = [:]
    public var cloneRoot: String = "~/src"
    /// 0 = automatic fetching off.
    public var defaultFetchIntervalMinutes: Int = 0
    public var gitPath: String = ""
    /// Most git processes Grove runs at once.
    public var maxParallelGitRuns: Int = GitLimiter.defaultLimit
    public var launchers: [Launcher] = Launcher.defaults
    public var pauseFetchInLowPowerMode: Bool = true
    /// Look up GitHub pull requests with the GitHub CLI (`gh`). When off, Grove never runs `gh`.
    public var gitHubPullRequests: Bool = true
    /// Repo list sections, in order.
    public var groups: [RepoGroup] = []
    /// Custom order of repos not in any group; unlisted repos follow by name.
    public var ungroupedOrder: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        // Decode leniently so new fields don't invalidate an existing config file.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        repositories = try c.decodeIfPresent([String].self, forKey: .repositories) ?? d.repositories
        scanRoots = try c.decodeIfPresent([ScanRoot].self, forKey: .scanRoots) ?? d.scanRoots
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? d.excluded
        repoSettings = try c.decodeIfPresent([String: RepoSettings].self, forKey: .repoSettings) ?? d.repoSettings
        cloneRoot = try c.decodeIfPresent(String.self, forKey: .cloneRoot) ?? d.cloneRoot
        defaultFetchIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultFetchIntervalMinutes) ?? d.defaultFetchIntervalMinutes
        gitPath = try c.decodeIfPresent(String.self, forKey: .gitPath) ?? d.gitPath
        maxParallelGitRuns = try c.decodeIfPresent(Int.self, forKey: .maxParallelGitRuns) ?? d.maxParallelGitRuns
        launchers = try c.decodeIfPresent([Launcher].self, forKey: .launchers) ?? d.launchers
        pauseFetchInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseFetchInLowPowerMode) ?? d.pauseFetchInLowPowerMode
        gitHubPullRequests = try c.decodeIfPresent(Bool.self, forKey: .gitHubPullRequests) ?? d.gitHubPullRequests
        groups = try c.decodeIfPresent([RepoGroup].self, forKey: .groups) ?? d.groups
        ungroupedOrder = try c.decodeIfPresent([String].self, forKey: .ungroupedOrder) ?? d.ungroupedOrder
    }

    public func settings(for path: String) -> RepoSettings {
        repoSettings[path] ?? RepoSettings()
    }

    /// `path`'s settings, with defaults from its profile; `detected` is the profile its size suggests.
    public func effectiveSettings(for path: String, detected: RepoProfile) -> EffectiveRepoSettings {
        let custom = settings(for: path)
        var result = EffectiveRepoSettings.defaults(custom.profile ?? detected, defaultFetchIntervalMinutes: defaultFetchIntervalMinutes)
        if let v = custom.fetchIntervalMinutes { result.fetchIntervalMinutes = v }
        if let v = custom.fetchScope { result.fetchScope = v }
        if let v = custom.fetchTags { result.fetchTags = v }
        if let v = custom.compareAllBranches { result.compareAllBranches = v }
        if let v = custom.lineCounts { result.lineCounts = v }
        return result
    }
}

/// Loads and saves `AppConfig` as JSON in Application Support.
public struct ConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appendingPathComponent("Grove/config.json")
        }
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}

public extension String {
    /// Expands a leading `~` to the home directory.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
