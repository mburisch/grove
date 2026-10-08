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

    // MARK: diff --numstat / log

    /// Parses `git diff --numstat -z`: `ins<TAB>del<TAB>path<NUL>`, or for renames
    /// `ins<TAB>del<TAB><NUL>old<NUL>new<NUL>`. Binary files report `-` counts.
    /// Returns counts keyed by (new) path, with the old path for renames.
    public static func parseNumstat(_ output: String) -> [(path: String, oldPath: String?, insertions: Int?, deletions: Int?)] {
        var result: [(path: String, oldPath: String?, insertions: Int?, deletions: Int?)] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let record = fields.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            var oldPath: String?
            if path.isEmpty, let old = fields.popFirst(), let new = fields.popFirst() {
                oldPath = old
                path = new
            }
            result.append((path, oldPath, Int(parts[0]), Int(parts[1])))
        }
        return result
    }

    /// Parses `git diff --name-status -z`: `X<NUL>path<NUL>`, or `R100<NUL>old<NUL>new<NUL>` for renames/copies.
    /// Returns the one-letter status keyed by (new) path.
    public static func parseNameStatus(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let code = fields.popFirst(), let letter = code.first {
            if letter == "R" || letter == "C" {
                _ = fields.popFirst()
            }
            guard let path = fields.popFirst() else { break }
            result[path] = String(letter)
        }
        return result
    }

    /// Combines `--numstat -z` and `--name-status -z` output for the same diff.
    public static func parseFileChanges(numstat: String, nameStatus: String) -> [FileChange] {
        let statuses = parseNameStatus(nameStatus)
        return parseNumstat(numstat).map { entry in
            FileChange(
                status: statuses[entry.path] ?? (entry.oldPath == nil ? "M" : "R"),
                path: entry.path,
                oldPath: entry.oldPath,
                insertions: entry.insertions,
                deletions: entry.deletions
            )
        }
    }

    /// Format for `git log` parsed by `parseLog`.
    public static let logFormat = "%H%x00%s%x00%an%x00%ct"

    public static func parseLog(_ output: String) -> [CommitSummary] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 else { return nil }
            return CommitSummary(sha: f[0], subject: f[1], author: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0))
        }
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

    // MARK: diff (unified)

    /// Lines kept per file diff; the rest are dropped and `FileDiff.truncated` is set.
    public static let maxDiffLines = 20_000

    /// Parses `git diff` output for one file into hunks with old/new line numbers.
    public static func parseUnifiedDiff(_ output: String) -> FileDiff {
        var diff = FileDiff()
        var hunk: DiffHunk?
        var oldLine = 0, newLine = 0, count = 0
        func finishHunk() {
            if let hunk { diff.hunks.append(hunk) }
            hunk = nil
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                finishHunk()
                if count >= maxDiffLines { diff.truncated = true; break }
                if let match = line.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                    oldLine = Int(match.1) ?? 0
                    newLine = Int(match.2) ?? 0
                }
                hunk = DiffHunk(header: line, lines: [])
                continue
            }
            if hunk == nil || line.hasPrefix("diff ") {
                // File header: diff --git, index, ---/+++, mode and rename lines.
                finishHunk()
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { diff.isBinary = true }
                continue
            }
            if count >= maxDiffLines { diff.truncated = true; break }
            switch line.first {
            case "+":
                hunk?.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            case "-":
                hunk?.lines.append(DiffLine(kind: .removed, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            case " ":
                hunk?.lines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            case "\\":
                hunk?.lines.append(DiffLine(kind: .note, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
            default:
                continue  // The empty string after the final newline.
            }
            count += 1
        }
        finishHunk()
        return diff
    }

    // MARK: helpers

    private static func splitKeyValue<S: StringProtocol>(_ line: S) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (String(line), "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
