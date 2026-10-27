import Foundation

/// Git settings that make git faster in big repositories, each turned on or off on its own. They go
/// in the repository's own config, which its worktrees share, and also apply to the git commands
/// the user runs.
public struct RepoTuning: Sendable, Hashable {
    public enum Option: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// A background process per worktree tells git which files changed, so status doesn't
        /// look at every file.
        case fsmonitor
        /// Status re-reads only folders that changed when looking for untracked files.
        case untrackedCache
        /// A smaller index format that git reads and writes faster (`index.version=4`, and from
        /// git 2.40 `index.skipHash`). Tools with their own git engine (libgit2, JGit) and older
        /// git may not read that index.
        case manyFiles
        /// A commit graph kept current after each fetch, which speeds up the ahead/behind counts
        /// and merge bases Grove computes (gc writes it too, but large repos fetch without
        /// `gc --auto`; see `FetchOptions.autoGC`).
        case commitGraph

        public var id: String { rawValue }

        public var key: String {
            switch self {
            case .fsmonitor: "core.fsmonitor"
            case .untrackedCache: "core.untrackedCache"
            case .manyFiles: "feature.manyFiles"
            case .commitGraph: "fetch.writeCommitGraph"
            }
        }

        public var title: String {
            switch self {
            case .fsmonitor: "File system monitor"
            case .untrackedCache: "Untracked cache"
            case .manyFiles: "Many-files index"
            case .commitGraph: "Commit graph after fetch"
            }
        }

        public var summary: String {
            switch self {
            case .fsmonitor:
                "A background process per worktree (git fsmonitor--daemon) tells git what changed, so status "
                    + "doesn't look at every file. Uses some memory, and CPU while many files change."
            case .untrackedCache:
                "Status re-reads only folders that changed when looking for untracked files."
            case .manyFiles:
                "A faster, smaller index format. Git apps and editor plugins with their own git engine "
                    + "(libgit2, JGit) and git older than 2.40 may fail to read the repository."
            case .commitGraph:
                "Keeps a commit graph current after each fetch, which speeds up ahead/behind counts."
            }
        }

        /// Turned on by the suggested optimization: no compatibility risk.
        public var isRecommended: Bool { self != .manyFiles }
        /// Keeps its state in the index, which then needs writing now and then (`SnapshotOptions.writeIndexIn`).
        var usesIndex: Bool { self == .fsmonitor || self == .untrackedCache }
    }

    public struct Setting: Sendable, Hashable, Identifiable {
        public var option: Option
        /// The value git uses now (from any config file), nil when unset.
        public var current: String?
        /// Why it can't be changed here; nil when it can.
        public var unavailable: String?

        public var id: Option { option }
        /// On, including a monitor hook (e.g. Watchman) set as `core.fsmonitor`.
        public var isOn: Bool {
            RepoTuning.isTrue(current) || (option == .fsmonitor && current.map { !$0.isEmpty && !RepoTuning.isBoolean($0) } == true)
        }
    }

    /// One setting to turn on or off.
    public struct Change: Sendable, Hashable {
        public var option: Option
        public var turnOn: Bool
    }

    public var settings: [Setting]

    public init(settings: [Setting]) {
        self.settings = settings
    }

    public func setting(_ option: Option) -> Setting? { settings.first { $0.option == option } }

    public var enabled: Set<Option> { Set(settings.filter(\.isOn).map(\.option)) }

    /// What's on now plus the recommended options that can be turned on.
    public var suggested: Set<Option> {
        enabled.union(settings.filter { $0.option.isRecommended && $0.unavailable == nil }.map(\.option))
    }

    /// Every recommended option that can be on is on.
    public var isOptimized: Bool { suggested.isSubset(of: enabled) }

    /// The monitor or the untracked cache is on, so the index holds state that goes stale.
    public var usesIndexCaches: Bool { settings.contains { $0.option.usesIndex && $0.isOn } }

    /// The changes that take the settings to `wanted`, leaving alone those that can't change.
    public func changes(to wanted: Set<Option>) -> [Change] {
        settings.compactMap { setting in
            let on = wanted.contains(setting.option)
            guard on != setting.isOn, setting.unavailable == nil else { return nil }
            return Change(option: setting.option, turnOn: on)
        }
    }

    /// The settings and what can be changed, given the current values (nil = unset).
    public static func plan(fsmonitor: String?, untrackedCache: String?, manyFiles: String?, splitIndex: String?,
                            writeCommitGraph: String?, fsmonitorAvailable: Bool) -> RepoTuning {
        var monitor = Setting(option: .fsmonitor, current: fsmonitor)
        if let fsmonitor, !fsmonitor.isEmpty, !isBoolean(fsmonitor) {
            monitor.unavailable = "Uses a hook (\(fsmonitor)), left as it is."
        } else if !fsmonitorAvailable && !monitor.isOn {
            monitor.unavailable = "This git has no built-in file system monitor (git 2.36 or later, built with it)."
        }
        var many = Setting(option: .manyFiles, current: manyFiles)
        if isTrue(splitIndex) && !many.isOn {
            many.unavailable = "core.splitIndex is on, and the two together can corrupt the index."
        }
        return RepoTuning(settings: [
            monitor,
            // feature.manyFiles also turns the untracked cache on unless it's set itself.
            Setting(option: .untrackedCache, current: untrackedCache ?? (isTrue(manyFiles) ? "true" : nil)),
            many,
            Setting(option: .commitGraph, current: writeCommitGraph),
        ])
    }

    static func isTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["true", "yes", "on", "1"].contains(value.lowercased())
    }

    static func isBoolean(_ value: String) -> Bool {
        ["true", "yes", "on", "1", "false", "no", "off", "0"].contains(value.lowercased())
    }
}

extension GitRepository {
    /// Current values of the tuning settings.
    public func tuning() async -> RepoTuning {
        async let fsmonitor = git.outputIfSuccess(["config", "--get", "core.fsmonitor"], in: url)
        async let untrackedCache = git.outputIfSuccess(["config", "--get", "core.untrackedCache"], in: url)
        async let manyFiles = git.outputIfSuccess(["config", "--get", "feature.manyFiles"], in: url)
        async let splitIndex = git.outputIfSuccess(["config", "--get", "core.splitIndex"], in: url)
        async let writeCommitGraph = git.outputIfSuccess(["config", "--get", "fetch.writeCommitGraph"], in: url)
        async let options = git.outputIfSuccess(["version", "--build-options"], in: url)
        let available = (await options ?? "").split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "feature: fsmonitor--daemon" }
        return RepoTuning.plan(fsmonitor: await fsmonitor, untrackedCache: await untrackedCache, manyFiles: await manyFiles,
                               splitIndex: await splitIndex, writeCommitGraph: await writeCommitGraph,
                               fsmonitorAvailable: available)
    }

    /// Writes `changes` to the repository's config ("false" to turn one off, which also beats a
    /// "true" from the global config), then puts each worktree's index in line:
    /// - Turning the commit graph on writes one now; later fetches keep it current.
    /// - Turning the many-files index on or off rewrites the index in the new or the classic format
    ///   (off: so other git tools can read it again right away).
    /// - Turning the untracked cache off drops it from the index; turning the monitor off stops
    ///   its background processes.
    /// - Turning the monitor or untracked cache on runs one status that may write the index, which
    ///   stores the cache and the monitor's position and starts the monitor. (Grove's other status
    ///   runs never write the index; see `GitRunner`.)
    public func applyTuning(_ changes: [RepoTuning.Change]) async throws {
        for change in changes {
            try await git.run(["config", "--local", change.option.key, change.turnOn ? "true" : "false"], in: url)
        }
        let turnedOn = Set(changes.filter(\.turnOn).map(\.option))
        let turnedOff = Set(changes.filter { !$0.turnOn }.map(\.option))
        if turnedOn.contains(.commitGraph) {
            try await git.run(["commit-graph", "write", "--reachable", "--split"], in: url, timeout: .seconds(3600))
        }
        let worktrees = GitParsers.parseWorktrees(try await git.output(["worktree", "list", "--porcelain"], in: url))
            .filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path) }
        for worktree in worktrees {
            let dir = URL(fileURLWithPath: worktree.path)
            if turnedOff.contains(.fsmonitor) {
                try await git.run(["fsmonitor--daemon", "stop"], in: dir, check: false)
            }
            if turnedOff.contains(.untrackedCache) {
                try await git.run(["update-index", "--no-untracked-cache"], in: dir)
            }
            // index.version only applies to new index files, so convert the existing one either way.
            if turnedOn.contains(.manyFiles) {
                try await git.run(["update-index", "--index-version", "4"], in: dir, timeout: .seconds(600))
            }
            if turnedOff.contains(.manyFiles) {
                try await git.run(["update-index", "--index-version", "2"], in: dir, timeout: .seconds(600))
            }
            if turnedOn.contains(where: \.usesIndex) {
                try await git.run(["status", "--porcelain"], in: dir, timeout: .seconds(600), optionalLocks: true)
            }
        }
    }
}
