import Foundation

/// A run of diff lines, either shown or folded away behind an "N unchanged lines" row.
public enum DiffSegment: Sendable, Hashable {
    case lines(Range<Int>)
    case folded(Range<Int>)
}

public enum DiffFolding {
    /// Splits `lines` so that only `context` unchanged lines stay visible around each change;
    /// longer unchanged runs are folded. Runs that would fold just a line or two stay visible.
    public static func segments(_ lines: [DiffLine], context: Int = 3) -> [DiffSegment] {
        var segments: [DiffSegment] = []
        var shownStart = 0
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .context else { index += 1; continue }
            var end = index
            while end < lines.count, lines[end].kind == .context { end += 1 }
            // Keep context after the previous change and before the next one, but not past the file's edges.
            let keepBefore = index == 0 ? 0 : context
            let keepAfter = end == lines.count ? 0 : context
            let foldStart = index + keepBefore
            let foldEnd = end - keepAfter
            if foldEnd - foldStart > 2 {
                if foldStart > shownStart { segments.append(.lines(shownStart..<foldStart)) }
                segments.append(.folded(foldStart..<foldEnd))
                shownStart = foldEnd
            }
            index = end
        }
        if shownStart < lines.count { segments.append(.lines(shownStart..<lines.count)) }
        return segments
    }

    /// Start indices of each block of consecutive added/removed lines.
    public static func changeStarts(_ lines: [DiffLine]) -> [Int] {
        var starts: [Int] = []
        var previousChanged = false
        for (i, line) in lines.enumerated() {
            let changed = line.kind == .added || line.kind == .removed
            if changed && !previousChanged { starts.append(i) }
            previousChanged = changed || (previousChanged && line.kind == .note)
        }
        return starts
    }
}
