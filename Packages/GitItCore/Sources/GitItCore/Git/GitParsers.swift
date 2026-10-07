import Foundation

/// Pure parsers for git's machine-readable output. Kept separate so they can be tested on fixtures.
public enum GitParsers {
    // MARK: for-each-ref

    /// Format string used with `git for-each-ref`; fields are NUL-separated, one ref per line.
    public static let refFormat = [
        "%(refname)", "%(objectname)", "%(upstream:short)", "%(upstream:track,nobracket)",
        "%(subject)", "%(authorname)", "%(committerdate:unix)", "%(worktreepath)", "%(symref)",
    ].joined(separator: "%00")

    public struct RefRecord: Sendable, Hashable {
        public var refname: String
        public var sha: String
        public var upstream: String?
        public var track: String
        public var subject: String
        public var author: String
        public var date: Date
        public var worktreePath: String?
        public var isSymref: Bool

        public var commit: CommitSummary {
            CommitSummary(sha: sha, subject: subject, author: author, date: date)
        }
    }

    public static func parseRefs(_ output: String) -> [RefRecord] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 9 else { return nil }
            return RefRecord(
                refname: f[0],
                sha: f[1],
                upstream: f[2].isEmpty ? nil : f[2],
                track: f[3],
                subject: f[4],
                author: f[5],
                date: Date(timeIntervalSince1970: TimeInterval(f[6]) ?? 0),
                worktreePath: f[7].isEmpty ? nil : f[7],
                isSymref: !f[8].isEmpty
            )
        }
    }

    /// Parses `%(upstream:track,nobracket)`: "ahead 1, behind 2", "ahead 1", "behind 2", "gone", "".
    /// Returns nil for "gone"; `.zero` for an empty string (in sync).
    public static func parseTrack(_ track: String) -> AheadBehind? {
        if track == "gone" { return nil }
        var result = AheadBehind.zero
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { result.ahead = n }
            if words[0] == "behind" { result.behind = n }
        }
        return result
    }

    // MARK: rev-list

    /// Parses `git rev-list --left-right --count A...B` → (left only, right only).
    public static func parseLeftRight(_ output: String) -> AheadBehind? {
        let parts = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count == 2, let left = Int(parts[0]), let right = Int(parts[1]) else { return nil }
        return AheadBehind(ahead: left, behind: right)
    }

    // MARK: worktree list

    public struct WorktreeRecord: Sendable, Hashable {
        public var path: String
        public var head: String = ""
        public var branch: String?
        public var isBare = false
        public var isDetached = false
        public var isLocked = false
        public var isPrunable = false
    }

    public static func parseWorktrees(_ output: String) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var current: WorktreeRecord?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if let c = current { records.append(c) }
                current = nil
                continue
            }
            let (key, value) = splitKeyValue(line)
            switch key {
            case "worktree": current = WorktreeRecord(path: value)
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        if let c = current { records.append(c) }
        return records
    }

    // MARK: status --porcelain=v2 --branch

    public struct StatusRecord: Sendable, Hashable {
        public var branch: String?
        public var upstream: String?
        public var aheadBehind: AheadBehind?
        public var status = WorkingTreeStatus()
    }

    public static func parseStatus(_ output: String) -> StatusRecord {
        var record = StatusRecord()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# ") {
                let (key, value) = splitKeyValue(line.dropFirst(2))
                switch key {
                case "branch.head": record.branch = value == "(detached)" ? nil : value
                case "branch.upstream": record.upstream = value
                case "branch.ab":
                    let nums = value.split(separator: " ").compactMap { Int($0.dropFirst()) }
                    if nums.count == 2 { record.aheadBehind = AheadBehind(ahead: nums[0], behind: nums[1]) }
                default: break
                }
                continue
            }
            guard let kind = line.first else { continue }
            switch kind {
            case "1", "2":
                let xy = line.dropFirst(2).prefix(2)
                guard xy.count == 2 else { continue }
                if xy.first != "." { record.status.staged += 1 }
                if xy.last != "." { record.status.unstaged += 1 }
            case "u": record.status.conflicted += 1
            case "?": record.status.untracked += 1
            default: break
            }
        }
        return record
    }

    // MARK: diff --shortstat

    /// Parses " 3 files changed, 10 insertions(+), 2 deletions(-)". Empty output is `.zero`.
    public static func parseShortStat(_ output: String) -> DiffStat {
        var stat = DiffStat.zero
        for part in output.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let n = words.first.flatMap({ Int($0) }), words.count >= 2 else { continue }
            let word = words[1]
            if word.hasPrefix("file") { stat.files = n }
            else if word.hasPrefix("insertion") { stat.insertions = n }
            else if word.hasPrefix("deletion") { stat.deletions = n }
        }
        return stat
    }

    // MARK: clone/fetch progress

    public struct Progress: Sendable, Hashable {
        public var phase: String
        /// 0...1 across the whole operation.
        public var fraction: Double
    }

    /// Interprets one `--progress` line (git separates updates with `\r`).
    public static func parseProgress(_ line: String) -> Progress? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let phases: [(prefix: String, start: Double, span: Double)] = [
            ("remote: Enumerating objects", 0.00, 0.02),
            ("remote: Counting objects", 0.02, 0.03),
            ("remote: Compressing objects", 0.05, 0.05),
            ("Receiving objects", 0.10, 0.70),
            ("Resolving deltas", 0.80, 0.12),
            ("Updating files", 0.92, 0.08),
        ]
        guard let phase = phases.first(where: { text.hasPrefix($0.prefix) }) else { return nil }
        let percent = text.firstMatch(of: /(\d{1,3})%/).flatMap { Double($0.1) } ?? 0
        let name = phase.prefix.replacingOccurrences(of: "remote: ", with: "")
        return Progress(phase: name, fraction: phase.start + phase.span * percent / 100)
    }

    // MARK: helpers

    private static func splitKeyValue<S: StringProtocol>(_ line: S) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (String(line), "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
