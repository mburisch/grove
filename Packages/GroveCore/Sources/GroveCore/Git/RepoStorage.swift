import Foundation

/// How much space a repository's objects take, from `git count-objects -v`.
public struct RepoStorage: Sendable, Hashable {
    public var looseObjects: Int = 0
    public var looseBytes: Int64 = 0
    public var packs: Int = 0
    public var packBytes: Int64 = 0
    public var garbageBytes: Int64 = 0

    public init(looseObjects: Int = 0, looseBytes: Int64 = 0, packs: Int = 0, packBytes: Int64 = 0, garbageBytes: Int64 = 0) {
        self.looseObjects = looseObjects
        self.looseBytes = looseBytes
        self.packs = packs
        self.packBytes = packBytes
        self.garbageBytes = garbageBytes
    }

    public var totalBytes: Int64 { looseBytes + packBytes + garbageBytes }

    /// Many packs or loose objects: `git gc` would likely free space and speed git up.
    public var needsCleanUp: Bool { packs > 50 || looseObjects > 20_000 || garbageBytes > 100 << 20 }

    /// Parses `git count-objects -v` (sizes in KiB).
    public static func parse(_ output: String) -> RepoStorage? {
        var values: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let value = Int64(parts[1]) { values[parts[0]] = value }
        }
        guard let packs = values["packs"] else { return nil }
        return RepoStorage(looseObjects: Int(values["count"] ?? 0), looseBytes: (values["size"] ?? 0) * 1024,
                           packs: Int(packs), packBytes: (values["size-pack"] ?? 0) * 1024,
                           garbageBytes: (values["size-garbage"] ?? 0) * 1024)
    }
}

/// Whether `git maintenance` prefetches this repository in the background. Prefetch downloads every
/// remote branch into `refs/prefetch/` hourly, which on busy repositories piles up pack data.
public struct PrefetchStatus: Sendable, Hashable {
    /// The repository is registered with `git maintenance start`.
    public var scheduled: Bool
    /// Its scheduled maintenance includes the prefetch task.
    public var enabled: Bool
    public var refCount: Int

    public init(scheduled: Bool, enabled: Bool, refCount: Int) {
        self.scheduled = scheduled
        self.enabled = enabled
        self.refCount = refCount
    }

    public var isActive: Bool { scheduled && enabled }
}

extension GitRepository {
    public func storage() async -> RepoStorage? {
        await git.outputIfSuccess(["count-objects", "-v"], in: url).flatMap(RepoStorage.parse)
    }

    public func prefetchStatus() async -> PrefetchStatus {
        async let registered = git.outputIfSuccess(["config", "--global", "--get-all", "maintenance.repo"], in: url)
        async let enabledSetting = git.outputIfSuccess(["config", "--type=bool", "--get", "maintenance.prefetch.enabled"], in: url)
        async let schedule = git.outputIfSuccess(["config", "--get", "maintenance.prefetch.schedule"], in: url)
        async let strategy = git.outputIfSuccess(["config", "--get", "maintenance.strategy"], in: url)
        async let refs = git.outputIfSuccess(["for-each-ref", "--format=x", "refs/prefetch/"], in: url)
        let own = url.resolvingSymlinksInPath().standardizedFileURL.path
        let scheduled = (await registered ?? "").split(separator: "\n").contains {
            URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().standardizedFileURL.path == own
        }
        // `maintenance start` sets the incremental strategy, whose hourly run includes prefetch.
        let (scheduleValue, strategyValue, enabledValue, refList) = await (schedule, strategy, enabledSetting, refs)
        let enabled = enabledValue != "false" && (scheduleValue != nil || strategyValue == "incremental")
        let refCount = (refList ?? "").split(separator: "\n").count
        return PrefetchStatus(scheduled: scheduled, enabled: enabled, refCount: refCount)
    }

    /// Turns background prefetch on or off for this repository only. Turning it off also deletes
    /// `refs/prefetch/`, so the next clean-up can drop the data only those refs kept.
    public func setPrefetch(enabled: Bool) async throws {
        if enabled {
            try await git.run(["config", "--local", "--unset-all", "maintenance.prefetch.enabled"], in: url, check: false)
            return
        }
        try await git.run(["config", "--local", "maintenance.prefetch.enabled", "false"], in: url)
        let refs = try await git.output(["for-each-ref", "--format=delete %(refname)", "refs/prefetch/"], in: url)
        if !refs.isEmpty {
            try await git.run(["update-ref", "--stdin"], in: url, input: Data((refs + "\n").utf8))
        }
    }

    /// Runs `git gc`: repacks everything into one pack and deletes unreachable objects older than an
    /// hour (newer ones may belong to a git command running right now). Can take a long time.
    public func cleanUp() async throws {
        try await git.run(["gc", "--quiet", "--prune=1.hour.ago"], in: url, timeout: .seconds(4 * 3600))
    }
}
