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

/// Per-repository settings, keyed by path in `AppConfig.repoSettings`.
public struct RepoSettings: Codable, Sendable, Hashable {
    /// Minutes between automatic fetches; nil uses the global default, 0 disables.
    public var fetchIntervalMinutes: Int?
    /// Depth used when trimming a shallow checkout.
    public var shallowDepth: Int?

    public init(fetchIntervalMinutes: Int? = nil, shallowDepth: Int? = nil) {
        self.fetchIntervalMinutes = fetchIntervalMinutes
        self.shallowDepth = shallowDepth
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
        groups = try c.decodeIfPresent([RepoGroup].self, forKey: .groups) ?? d.groups
        ungroupedOrder = try c.decodeIfPresent([String].self, forKey: .ungroupedOrder) ?? d.ungroupedOrder
    }

    public func settings(for path: String) -> RepoSettings {
        repoSettings[path] ?? RepoSettings()
    }

    public func fetchInterval(for path: String) -> Int {
        settings(for: path).fetchIntervalMinutes ?? defaultFetchIntervalMinutes
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
