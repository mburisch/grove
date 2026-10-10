import Foundation

/// The ref branches are compared against, and the commit it points at.
public struct CompareTarget: Sendable, Hashable {
    public var ref: String
    public var sha: String

    public init(ref: String, sha: String) {
        self.ref = ref
        self.sha = sha
    }
}

/// Ahead/behind counts and diff stats by pair of commits, so a refresh where neither a branch nor
/// the primary branch moved runs no `rev-list` or `diff` for it.
public actor ComparisonCache {
    public struct Entry: Sendable, Hashable {
        public var count: AheadBehind?
        public var diff: DiffStat?
    }

    private var entries: [String: Entry] = [:]
    /// Keys read or written since the last `endPass`.
    private var used: Set<String> = []

    public init() {}

    private static func key(_ sha: String, _ target: CompareTarget) -> String { "\(sha)...\(target.sha)" }

    public func entry(_ sha: String, _ target: CompareTarget) -> Entry? {
        let key = Self.key(sha, target)
        used.insert(key)
        return entries[key]
    }

    public func store(_ sha: String, _ target: CompareTarget, count: AheadBehind?, diff: DiffStat?) {
        let key = Self.key(sha, target)
        used.insert(key)
        var entry = entries[key] ?? Entry()
        if let count { entry.count = count }
        if let diff { entry.diff = diff }
        entries[key] = entry
    }

    /// Drops entries no snapshot or lookup used since the previous pass, e.g. for commits a branch moved away from.
    public func endPass() {
        entries = entries.filter { used.contains($0.key) }
        used = []
    }

    public var count: Int { entries.count }
}
