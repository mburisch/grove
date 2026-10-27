import Foundation

/// Git settings that make `git status` fast in checkouts with many files: a file system monitor
/// (so git asks what changed instead of looking at every file), the untracked cache (so it only
/// re-reads folders that changed), and `feature.manyFiles` (a smaller, faster index format).
/// They go in the repository's own config, which its worktrees share.
public struct RepoTuning: Sendable, Hashable {
    public struct Setting: Sendable, Hashable, Identifiable {
        public var key: String
        /// The value git uses now (from any config file), nil when unset.
        public var current: String?
        /// The value to set; nil leaves the setting alone (see `note`).
        public var proposed: String?
        /// Why the setting is left alone, or what to know about it.
        public var note: String?

        public var id: String { key }
        public var needsChange: Bool { proposed != nil && !RepoTuning.isTrue(current) }
    }

    public var settings: [Setting]
    /// This git can run the built-in file system monitor (`git fsmonitor--daemon`).
    public var fsmonitorAvailable: Bool

    public var changes: [Setting] { settings.filter(\.needsChange) }
    /// Every setting that can be changed already has its proposed value.
    public var isApplied: Bool { changes.isEmpty }
    public var proposesFSMonitor: Bool { changes.contains { $0.key == "core.fsmonitor" } }

    public init(settings: [Setting], fsmonitorAvailable: Bool) {
        self.settings = settings
        self.fsmonitorAvailable = fsmonitorAvailable
    }

    /// What tuning would change, given the current values (nil = unset).
    public static func plan(fsmonitor: String?, untrackedCache: String?, manyFiles: String?, splitIndex: String?,
                            fsmonitorAvailable: Bool) -> RepoTuning {
        var settings: [Setting] = []

        var monitor = Setting(key: "core.fsmonitor", current: fsmonitor, proposed: "true")
        if let fsmonitor, !fsmonitor.isEmpty, !isBoolean(fsmonitor) {
            monitor.proposed = nil
            monitor.note = "Already uses a hook (\(fsmonitor)); left as it is."
        } else if !fsmonitorAvailable {
            monitor.proposed = nil
            monitor.note = "This git has no built-in file system monitor (git 2.36 or later, built with it)."
        }
        settings.append(monitor)

        settings.append(Setting(key: "core.untrackedCache", current: untrackedCache, proposed: "true"))

        var many = Setting(key: "feature.manyFiles", current: manyFiles, proposed: "true")
        if isTrue(splitIndex) && !isTrue(manyFiles) {
            many.proposed = nil
            many.note = "Skipped: core.splitIndex is on, and the two together can corrupt the index."
        }
        settings.append(many)

        return RepoTuning(settings: settings, fsmonitorAvailable: fsmonitorAvailable)
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
    /// Current values of the tuning settings and what tuning would change.
    public func tuning() async -> RepoTuning {
        async let fsmonitor = git.outputIfSuccess(["config", "--get", "core.fsmonitor"], in: url)
        async let untrackedCache = git.outputIfSuccess(["config", "--get", "core.untrackedCache"], in: url)
        async let manyFiles = git.outputIfSuccess(["config", "--get", "feature.manyFiles"], in: url)
        async let splitIndex = git.outputIfSuccess(["config", "--get", "core.splitIndex"], in: url)
        async let options = git.outputIfSuccess(["version", "--build-options"], in: url)
        let available = (await options ?? "").split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "feature: fsmonitor--daemon" }
        return RepoTuning.plan(fsmonitor: await fsmonitor, untrackedCache: await untrackedCache, manyFiles: await manyFiles,
                               splitIndex: await splitIndex, fsmonitorAvailable: available)
    }

    /// Sets the proposed values in the repository's config, then runs one status in each worktree
    /// that may write the index, which stores the untracked cache and the monitor's position and
    /// starts the monitor. (Grove's other status runs never write the index; see `GitRunner`.)
    public func applyTuning(_ tuning: RepoTuning) async throws {
        for setting in tuning.changes {
            guard let value = setting.proposed else { continue }
            try await git.run(["config", "--local", setting.key, value], in: url)
        }
        let worktrees = GitParsers.parseWorktrees(try await git.output(["worktree", "list", "--porcelain"], in: url))
            .filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path) }
        for worktree in worktrees {
            try await git.run(["status", "--porcelain"], in: URL(fileURLWithPath: worktree.path),
                              timeout: .seconds(600), optionalLocks: true)
        }
    }
}
