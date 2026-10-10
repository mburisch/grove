import AppKit
import GroveCore
import SwiftUI

/// Changed files of a worktree or branch in a sidebar, and the selected file's diff beside it.
struct DiffBrowser: View {
    let request: DiffRequest

    var body: some View {
        HStack(spacing: 0) {
            DiffSidebar(request: request)
                .frame(width: 250)
            Divider()
            DiffPane(request: request)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar

private struct DiffSidebar: View {
    @Environment(AppModel.self) private var model
    let request: DiffRequest

    var body: some View {
        let sections = model.diffSections(for: request)
        if sections.isEmpty {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { model.diffSelection }, set: { if let s = $0 { model.selectDiffFile(s) } })) {
                ForEach(sections) { section in
                    Section {
                        if section.files.isEmpty {
                            Text("No changes").font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(section.files) { file in
                            SidebarFileRow(request: request, file: file)
                                .tag(DiffSelection(file: file, scope: section.scope))
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            Text("\(section.files.count)").monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SidebarFileRow: View {
    @Environment(AppModel.self) private var model
    let request: DiffRequest
    let file: FileChange

    var body: some View {
        HStack(spacing: 6) {
            Text(file.status)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(statusColor(file.status))
                .frame(width: 16, height: 16)
                .background(statusColor(file.status).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 0) {
                Text((file.path as NSString).lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .strikethrough(file.isDeleted)
                let directory = (file.path as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let ins = file.insertions, let del = file.deletions {
                HStack(spacing: 3) {
                    if ins > 0 { Text("+\(ins)").foregroundStyle(.green) }
                    if del > 0 { Text("−\(del)").foregroundStyle(.red) }
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .font(.caption)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            ForEach(model.fileLaunchers) { editor in
                Button("Open in \(editor.name)") { openFile(file, in: request, with: editor, model: model) }
            }
            .disabled(!isOpenable(file, in: request))
            Button("Copy Relative Path") { copyToPasteboard(file.path) }
        }
    }
}

// MARK: - Diff pane

private struct DiffPane: View {
    @Environment(AppModel.self) private var model
    let request: DiffRequest

    var body: some View {
        if let selection = model.diffSelection {
            VStack(spacing: 0) {
                if let diff = model.currentDiff {
                    // Keyed by file so fold and navigation state start fresh for each one.
                    FileDiffView(request: request, selection: selection, diff: diff)
                        .id(selection)
                } else {
                    DiffHeader(request: request, selection: selection, navigation: nil)
                    Divider()
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Text(model.diffSections(for: request).allSatisfy(\.files.isEmpty) ? "No changes" : "Select a file")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Navigation state shared between the header's buttons and the diff body.
private struct ChangeNavigation {
    let count: Int
    let current: Int?
    let previous: () -> Void
    let next: () -> Void
    let allExpanded: Bool
    let canFold: Bool
    let toggleExpandAll: () -> Void
}

private struct FileDiffView: View {
    let request: DiffRequest
    let selection: DiffSelection
    let diff: FileDiff

    @State private var expanded: Set<Int> = []
    @State private var expandAll = false
    @State private var current: Int?
    @State private var scrollTarget: Int?

    private var lines: [DiffLine] { diff.hunks.flatMap(\.lines) }

    var body: some View {
        let lines = lines
        let segments = DiffFolding.segments(lines)
        let starts = DiffFolding.changeStarts(lines)
        let foldStarts = segments.compactMap { if case .folded(let r) = $0 { r.lowerBound } else { nil } }
        let navigation = ChangeNavigation(
            count: starts.count,
            current: current,
            previous: { go(to: current.map { max($0 - 1, 0) } ?? starts.count - 1, starts: starts) },
            next: { go(to: current.map { min($0 + 1, starts.count - 1) } ?? 0, starts: starts) },
            allExpanded: expandAll || (!foldStarts.isEmpty && Set(foldStarts).isSubset(of: expanded)),
            canFold: !foldStarts.isEmpty,
            toggleExpandAll: {
                if expandAll || Set(foldStarts).isSubset(of: expanded) { expandAll = false; expanded = [] } else { expandAll = true }
            }
        )
        VStack(spacing: 0) {
            DiffHeader(request: request, selection: selection, navigation: navigation)
            Divider()
            if diff.isBinary {
                note("Binary file — no text diff")
            } else if lines.isEmpty {
                note(selection.file.oldPath != nil ? "Renamed without changes" : "No differences")
            } else {
                body(lines: lines, segments: segments, starts: starts)
            }
        }
    }

    private func body(lines: [DiffLine], segments: [DiffSegment], starts: [Int]) -> some View {
        let highlighted = current.flatMap { blockRange(starts[$0], in: lines) }
        let gutter = gutterWidth(lines)
        let spans = changedSpans(lines)
        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .folded(let range) where !expandAll && !expanded.contains(range.lowerBound):
                            FoldRow(count: range.count) { expanded.insert(range.lowerBound) }
                        case .folded(let range), .lines(let range):
                            ForEach(range, id: \.self) { index in
                                DiffLineRow(line: lines[index], gutter: gutter,
                                            highlighted: highlighted?.contains(index) ?? false,
                                            changed: spans[index])
                                    .id(index)
                            }
                        }
                    }
                    if diff.truncated {
                        Text("Diff truncated after \(GitParsers.maxDiffLines.formatted()) lines; open the file to see the rest")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.bottom, 8)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.3)) }
                scrollTarget = nil
            }
            .onAppear {
                // Start at the first change, past any leading unchanged lines.
                if let first = starts.first, first > 0 { DispatchQueue.main.async { scrollTarget = first } }
            }
        }
    }

    private func go(to index: Int, starts: [Int]) {
        guard starts.indices.contains(index) else { return }
        current = index
        // The line before the change gives a little context at the top.
        scrollTarget = max(starts[index] - 1, 0)
    }

    /// The consecutive changed lines (and "no newline" notes) starting at `start`.
    private func blockRange(_ start: Int, in lines: [DiffLine]) -> Range<Int>? {
        var end = start
        while end < lines.count, lines[end].kind != .context { end += 1 }
        return start..<end
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Wide enough for the largest line number in the diff.
    private func gutterWidth(_ lines: [DiffLine]) -> CGFloat {
        let largest = lines.map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        return CGFloat(max(String(largest).count, 3)) * 7 + 8
    }
}

/// Folded unchanged lines; clicking unfolds them.
private struct FoldRow: View {
    let count: Int
    let expand: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                Text("Show \(count) unchanged lines")
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(hovering ? 0.16 : 0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show these lines")
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let gutter: CGFloat
    let highlighted: Bool
    /// Character offsets of the part that differs from the line's counterpart, if it has one.
    let changed: Range<Int>?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(highlighted ? Color.accentColor : .clear)
                .frame(width: 3)
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker).fontWeight(.bold).foregroundStyle(markerColor).frame(width: 14)
            Text(text)
                .foregroundStyle(line.kind == .note ? .secondary : .primary)
                .italic(line.kind == .note)
                .fixedSize()
                .padding(.trailing, 8)
        }
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var text: AttributedString {
        var text = AttributedString(line.text.isEmpty ? " " : line.text)
        if let changed {
            let start = text.index(text.startIndex, offsetByCharacters: changed.lowerBound)
            let end = text.index(text.startIndex, offsetByCharacters: changed.upperBound)
            text[start..<end].backgroundColor = markerColor.opacity(0.35)
        }
        return text
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(line.kind == .added || line.kind == .removed ? HierarchicalShapeStyle.secondary : .tertiary)
            .frame(width: gutter, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context, .note: ""
        }
    }

    private var markerColor: Color { line.kind == .added ? .green : .red }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.14)
        case .context, .note: .clear
        }
    }
}

private struct DiffHeader: View {
    @Environment(AppModel.self) private var model
    let request: DiffRequest
    let selection: DiffSelection
    let navigation: ChangeNavigation?

    private var file: FileChange { selection.file }

    var body: some View {
        let editors = model.fileLaunchers
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.status).foregroundStyle(statusColor(file.status)).monospaced()
                    path
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    if let ins = file.insertions, let del = file.deletions {
                        Text("+\(ins)").foregroundStyle(.green)
                        Text("−\(del)").foregroundStyle(.red)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let navigation, navigation.count > 0 {
                HStack(spacing: 2) {
                    Text(navigation.current.map { "Change \($0 + 1) of \(navigation.count)" }
                         ?? "\(navigation.count) change\(navigation.count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.trailing, 4)
                    Button(action: navigation.previous) { Image(systemName: "chevron.up") }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                        .help("Previous change (⌥↑)")
                    Button(action: navigation.next) { Image(systemName: "chevron.down") }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                        .help("Next change (⌥↓)")
                }
                .buttonStyle(.borderless)
            }
            if let navigation, navigation.canFold {
                Button(navigation.allExpanded ? "Collapse" : "Expand All", action: navigation.toggleExpandAll)
                    .controlSize(.small)
                    .fixedSize()
            }
            if let first = editors.first {
                Menu("Open in \(first.name)") {
                    ForEach(editors.dropFirst()) { editor in
                        Button("Open in \(editor.name)") { openFile(file, in: request, with: editor, model: model) }
                    }
                } primaryAction: {
                    openFile(file, in: request, with: first, model: model)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!isOpenable(file, in: request))
                .help(isBranch ? "Opens a read-only copy of the branch's version" : "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isBranch: Bool {
        if case .branch = request.target { true } else { false }
    }

    /// The folder dimmed and the file name emphasized; a rename shows both paths plainly.
    private var path: Text {
        if let oldPath = file.oldPath { return Text("\(oldPath) → \(file.path)") }
        let directory = (file.path as NSString).deletingLastPathComponent
        let name = Text((file.path as NSString).lastPathComponent).fontWeight(.semibold)
        return directory.isEmpty ? name : Text("\(Text(directory + "/").foregroundStyle(.secondary))\(name)")
    }

    private var caption: String {
        switch selection.scope {
        case .uncommitted: "Uncommitted changes"
        case .sinceBase(_, let primary): "Changed since this branch forked from \(primary), including uncommitted changes"
        case .branch(_, let primary): "Changed since this branch forked from \(primary)"
        }
    }
}

// MARK: - Shared

/// Same rules as the Inspector's file lists: no deleted files, and no binary files from a branch.
private func isOpenable(_ file: FileChange, in request: DiffRequest) -> Bool {
    if file.isDeleted { return false }
    if case .branch = request.target { return file.insertions != nil }
    return true
}

@MainActor
private func openFile(_ file: FileChange, in request: DiffRequest, with editor: Launcher, model: AppModel) {
    switch request.target {
    case .branch(let name):
        guard let repo = model.repo(at: request.repo) else { return }
        Task { await model.openFile(file.path, onBranch: name, in: repo, with: editor) }
    case .worktree(let path):
        model.open((path as NSString).appendingPathComponent(file.path), with: editor)
    }
}

/// Where a removed line and the added line that replaces it differ, as character offsets keyed
/// by line index. Only blocks of removed lines followed by as many added lines are paired up.
private func changedSpans(_ lines: [DiffLine]) -> [Int: Range<Int>] {
    var spans: [Int: Range<Int>] = [:]
    var index = 0
    while index < lines.count {
        guard lines[index].kind == .removed else { index += 1; continue }
        var added = index
        while added < lines.count, lines[added].kind == .removed { added += 1 }
        var end = added
        while end < lines.count, lines[end].kind == .added { end += 1 }
        if added - index == end - added {
            for offset in 0..<(added - index) {
                let old = Array(lines[index + offset].text), new = Array(lines[added + offset].text)
                let shortest = min(old.count, new.count)
                var prefix = 0
                while prefix < shortest, old[prefix] == new[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < shortest - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
                // Lines sharing nothing but indentation are different lines, not an edit.
                guard suffix > 0 || old[..<prefix].contains(where: { !$0.isWhitespace }) else { continue }
                if old.count - suffix > prefix { spans[index + offset] = prefix..<(old.count - suffix) }
                if new.count - suffix > prefix { spans[added + offset] = prefix..<(new.count - suffix) }
            }
        }
        index = max(end, index + 1)
    }
    return spans
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "A", "?": .green
    case "D": .red
    case "R", "C": .blue
    default: .orange
    }
}
