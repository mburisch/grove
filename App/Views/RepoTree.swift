import AppKit
import GroveCore
import SwiftUI

/// Column widths shared by repo, worktree and branch rows so status and actions line up.
private enum Column {
    static let status: CGFloat = 130
    static let actions: CGFloat = 78
    static let indent: CGFloat = 20
}

/// Repositories with their linked worktrees nested underneath.
struct RepoTree: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.repos.isEmpty {
            VStack(spacing: 8) {
                Text("No repositories").font(.headline)
                Text("Add a folder, a scan folder in Settings, or clone a GitHub URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clone…") { model.pane = .clone }
                Button("Settings") { model.pane = .settings }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let selection = Binding<Pane?>(
                get: { model.pane },
                set: { if let pane = $0 { model.select(pane) } else { model.pane = nil } }
            )
            List(selection: selection) {
                let sections = model.repoSections
                let showHeaders = !model.config.groups.isEmpty
                ForEach(sections, id: \.group?.id) { section in
                    let collapsed = section.group?.collapsed ?? false
                    Section {
                        if !collapsed {
                            if section.repos.isEmpty, let group = section.group {
                                EmptyGroupRow(group: group.id)
                            }
                            ForEach(Array(section.repos.enumerated()), id: \.element.id) { index, repo in
                                repoRows(repo, group: section.group?.id,
                                         next: index + 1 < section.repos.count ? section.repos[index + 1].path : nil)
                            }
                        }
                    } header: {
                        if showHeaders { GroupHeader(group: section.group, count: section.repos.count) }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .background(DragAutoScroller(active: Binding(
                get: { model.draggingInTree },
                set: { model.draggingInTree = $0 }
            )))
        }
    }

    @ViewBuilder
    private func repoRows(_ repo: RepoState, group: RepoGroup.ID?, next: String?) -> some View {
        let linked = (repo.snapshot?.worktrees.filter { !$0.isMain } ?? [])
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let free = (repo.snapshot?.branches.filter { $0.worktreePath == nil } ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let expanded = !model.collapsed.contains(repo.path)
        RepoTreeRow(repo: repo, hasChildren: !linked.isEmpty || !free.isEmpty, expanded: expanded)
            .tag(Pane.repo(repo.path))
            .contextMenu { RepoContextMenu(repo: repo) }
            .draggable(DragItem.repo(repo.path).payload)
            // Dropping on a repo inserts before it.
            .modifier(RepoDropTarget(group: group, before: repo.path))
        if expanded {
            ForEach(linked) { wt in
                WorktreeTreeRow(repo: repo, worktree: wt)
                    .tag(Pane.worktree(repo: repo.path, path: wt.path))
                    .contextMenu { WorktreeContextMenu(worktree: wt) }
                    // Dropping on a worktree inserts after its repo.
                    .modifier(RepoDropTarget(group: group, before: next))
            }
            if !free.isEmpty {
                BranchesHeaderRow(repo: repo, count: free.count)
                    .modifier(RepoDropTarget(group: group, before: next))
                if model.branchesExpanded.contains(repo.path) {
                    ForEach(free) { branch in
                        BranchTreeRow(repo: repo, branch: branch)
                            .tag(Pane.branch(repo: repo.path, name: branch.name))
                            .contextMenu { BranchContextMenu(repo: repo, branch: branch) }
                            .modifier(RepoDropTarget(group: group, before: next))
                    }
                }
            }
        }
    }
}

private extension WorktreeInfo {
    /// The tree's label: the checked-out branch, or the commit for a detached HEAD.
    var displayName: String { branch ?? "detached @ \(head.prefix(7))" }
}

/// Drag payloads are plain strings so they work with `draggable`/`dropDestination` without a custom UTType.
enum DragItem {
    case repo(String)
    case group(RepoGroup.ID)

    var payload: String {
        switch self {
        case .repo(let path): "grove-repo:" + path
        case .group(let id): "grove-group:" + id.uuidString
        }
    }

    init?(payload: String) {
        if payload.hasPrefix("grove-repo:") {
            self = .repo(String(payload.dropFirst("grove-repo:".count)))
        } else if payload.hasPrefix("grove-group:"), let id = UUID(uuidString: String(payload.dropFirst("grove-group:".count))) {
            self = .group(id)
        } else {
            return nil
        }
    }
}

/// Accepts dragged repos and inserts them into `group` before `before` (nil = at the end),
/// drawing an insertion line while targeted.
private struct RepoDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let group: RepoGroup.ID?
    let before: String?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: before == nil ? .bottom : .top) {
                if targeted {
                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: before == nil ? 3 : -3)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                var moved = false
                for case .repo(let path) in items.compactMap(DragItem.init(payload:)) {
                    model.moveRepo(path, to: group, before: before)
                    moved = true
                }
                return moved
            } isTargeted: { targeted = $0; if $0 { model.draggingInTree = true } }
    }
}

private struct EmptyGroupRow: View {
    let group: RepoGroup.ID

    var body: some View {
        Text("Drag repositories here")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
            .padding(.vertical, 4)
            .modifier(RepoDropTarget(group: group, before: nil))
    }
}

/// Section header: collapse, inline rename, count, and a menu. Repos dropped here go to the end
/// of the group; groups dropped here move before it (or to the end, on the ungrouped header).
private struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: RepoGroup?
    let count: Int
    @State private var name = ""
    @State private var targeted = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let group {
                DisclosureChevron(expanded: !group.collapsed, font: .caption2.weight(.bold)) {
                    model.toggleGroup(group.id)
                }
                if model.renamingGroup == group.id {
                    TextField("Group name", text: $name)
                        .textFieldStyle(.plain)
                        .focused($editing)
                        .onSubmit { model.renameGroup(group.id, to: name) }
                        .onExitCommand { model.renamingGroup = nil }
                        .onAppear { name = group.name; editing = true }
                        .onChange(of: editing) { if !editing { model.renameGroup(group.id, to: name) } }
                        .frame(maxWidth: 220)
                } else {
                    Text(group.name)
                        .onTapGesture(count: 2) { model.renamingGroup = group.id }
                }
            } else {
                Color.clear.frame(width: 12, height: 1)
                Text("Ungrouped")
            }
            Text("\(count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Rectangle().fill(.separator).frame(height: 1)
            IconButton("arrow.down.circle", help: group == nil ? "Fetch all ungrouped repos" : "Fetch all repos in this group") {
                Task { await model.fetch(group: group?.id) }
            }
            if let group {
                Menu {
                    Button("Fetch Group") { Task { await model.fetch(group: group.id) } }
                    Divider()
                    Button("Rename") { model.renamingGroup = group.id }
                    Button("Delete Group") { model.deleteGroup(group.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(targeted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .contextMenu {
            Button(group == nil ? "Fetch Ungrouped" : "Fetch Group") { Task { await model.fetch(group: group?.id) } }
            Divider()
            if let group {
                Button("Rename") { model.renamingGroup = group.id }
                Button("Delete Group") { model.deleteGroup(group.id) }
                Divider()
            }
            Button("New Group") { model.addGroup() }
        }
        .modifier(GroupDraggable(group: group))
        .dropDestination(for: String.self) { items, _ in
            var handled = false
            for item in items.compactMap(DragItem.init(payload:)) {
                switch item {
                case .repo(let path): model.moveRepo(path, to: group?.id)
                case .group(let id): model.moveGroup(id, before: group?.id)
                }
                handled = true
            }
            return handled
        } isTargeted: { targeted = $0; if $0 { model.draggingInTree = true } }
    }
}

/// Only real groups can be dragged to reorder; the ungrouped section stays last.
private struct GroupDraggable: ViewModifier {
    let group: RepoGroup?

    func body(content: Content) -> some View {
        if let group {
            content.draggable(DragItem.group(group.id).payload)
        } else {
            content
        }
    }
}

private struct RepoTreeRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let hasChildren: Bool
    let expanded: Bool

    var body: some View {
        let main = repo.mainWorktree
        let primary = repo.snapshot?.primaryBranch
        HStack(spacing: 8) {
            DisclosureChevron(expanded: expanded) {
                if expanded { model.collapsed.insert(repo.path) } else { model.collapsed.remove(repo.path) }
            }
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // The name wins over the branch label when space runs out.
                    Text(repo.name).fontWeight(.semibold).lineLimit(1).layoutPriority(1).help(repo.name)
                    if let branch = main?.branch {
                        // Orange only when the default branch is known and this is another one.
                        let offPrimary = primary != nil && branch != primary
                        Text("(\(branch))")
                            .foregroundStyle(offPrimary ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(branch)
                    } else if let main {
                        Text("(\(main.head.prefix(7)))").foregroundStyle(.orange)
                    }
                    if main?.hasCommits == false {
                        Text("no commits").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let mode = repo.snapshot?.mode, mode != .full { ModeChip(mode: mode) }
                    AutoFetchChip(repo: repo)
                    if repo.showsStorageWarning, let storage = repo.storage {
                        Button { model.select(.repo(repo.path)) } label: {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("\(AppModel.describe(storage)): a clean-up could free space and speed up git. Click to show.")
                    }
                }
                PathText(path: repo.displayPath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusCell(
                worktree: main,
                activity: repo.activity,
                queued: repo.queued,
                error: repo.lastError,
                showTracking: true,
                loading: repo.snapshot == nil
            )

            HStack(spacing: 6) {
                IconButton("arrow.down.circle", help: fetchHelp) { Task { await model.fetch(repo) } }
                IconButton("arrow.down.to.line", help: "Pull now: fetch, then fast-forward clean worktrees") {
                    Task { await model.pull(repo) }
                }
                LaunchIconButton(path: repo.path)
            }
            .disabled(repo.activity != nil || repo.queued != nil)
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var fetchHelp: String {
        "Fetch now — " + (repo.lastFetch.map { "last fetched \($0.relative)" } ?? "never fetched")
    }
}

/// Shown when the repo is fetched automatically: a clock with the interval ("15m", "1h").
private struct AutoFetchChip: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState

    var body: some View {
        let minutes = model.settings(for: repo).fetchIntervalMinutes
        if minutes > 0 {
            HStack(spacing: 2) {
                Image(systemName: "clock.arrow.circlepath")
                Text(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h")
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(.blue)
            .help(help(minutes))
        }
    }

    private func help(_ minutes: Int) -> String {
        var text = "Auto-fetch every \(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h")"
        if let last = repo.lastFetch {
            let next = last.addingTimeInterval(Double(minutes) * 60)
            text += next > .now ? " — next \(next.relative)" : " — due now"
        }
        return text
    }
}

private struct WorktreeTreeRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let worktree: WorktreeInfo

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(worktree.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let pr = worktree.branch.flatMap({ repo.pullRequests[$0] }) {
                        PullRequestBadge(pr: pr)
                    }
                    if worktree.isPrunable {
                        Text("missing").font(.caption).foregroundStyle(.red)
                    }
                }
                PathText(path: worktree.path.abbreviatingWithTilde)
            }
            .padding(.leading, Column.indent)
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusCell(worktree: worktree, activity: nil, queued: nil, error: nil, showTracking: false, loading: false)

            HStack(spacing: 6) {
                if (worktree.tracking?.behind ?? 0) > 0 {
                    IconButton("arrow.down.to.line", help: "Fast-forward to upstream") {
                        Task { await model.pull(repo, worktree: worktree) }
                    }
                    .disabled(worktree.status.hasTrackedChanges || (worktree.tracking?.ahead ?? 0) > 0)
                }
                LaunchIconButton(path: worktree.path)
            }
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// "Branches (n)" under a repo's worktrees; toggles the list of local branches without a worktree.
private struct BranchesHeaderRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let count: Int

    var body: some View {
        let expanded = model.branchesExpanded.contains(repo.path)
        Button {
            if expanded { model.branchesExpanded.remove(repo.path) } else { model.branchesExpanded.insert(repo.path) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text("Branches")
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 12 + 8 + Column.indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

/// A local branch that isn't checked out in any worktree.
private struct BranchTreeRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: BranchInfo

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(branch.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(branch.name)
                    if let pr = repo.pullRequests[branch.name] {
                        PullRequestBadge(pr: pr)
                    }
                }
                // Where a worktree row shows its folder: the upstream and the last commit's age.
                HStack(spacing: 4) {
                    upstream.lineLimit(1).truncationMode(.middle)
                    Text("· \(branch.commit.date.relative)").foregroundStyle(.tertiary).lineLimit(1).layoutPriority(1)
                }
                .font(.caption)
            }
            .padding(.leading, Column.indent * 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if let diff = branch.committedDiff { CompactDiff(stat: diff) }
                AheadBehindBadge(value: branch.tracking, showSynced: false)
            }
            .frame(width: Column.status, alignment: .trailing)

            HStack(spacing: 6) {
                if let tracking = branch.tracking, tracking.behind > 0 {
                    IconButton("arrow.down.to.line", help: "Fast-forward to \(branch.upstream ?? "upstream")") {
                        Task { await model.fastForward(repo, branch: branch) }
                    }
                    .disabled(tracking.ahead > 0 || repo.activity != nil)
                }
            }
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var upstream: some View {
        if branch.upstreamGone {
            Text("upstream gone").foregroundStyle(.red)
        } else if let upstream = branch.upstream {
            Text(upstream).foregroundStyle(.secondary).help(upstream)
        } else {
            Text("no upstream").foregroundStyle(.tertiary)
        }
    }
}

/// Branch counterpart of `WorktreeContextMenu`.
struct BranchContextMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: BranchInfo

    var body: some View {
        // No "Create Worktree" here: that's only the button on the branch's page, which asks for a folder.
        if let tracking = branch.tracking, tracking.behind > 0, tracking.ahead == 0 {
            Button("Fast-Forward to \(branch.upstream ?? "Upstream")") {
                Task { await model.fastForward(repo, branch: branch) }
            }
            Divider()
        }
        Button("Copy Branch Name") { copyToPasteboard(branch.name) }
    }
}

private struct PathText: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

/// Dirty marker, diff vs primary and ahead/behind, right-aligned.
private struct StatusCell: View {
    let worktree: WorktreeInfo?
    let activity: String?
    /// Waiting for its turn in a batch, e.g. "Waiting to fetch".
    let queued: String?
    let error: String?
    /// Repo rows show ahead/behind vs upstream; worktree rows show their diff vs primary.
    let showTracking: Bool
    let loading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let activity {
                ProgressView().controlSize(.small)
                    .help(activity)
            } else if let queued {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .help(queued)
            } else if loading {
                ProgressView().controlSize(.small)
            }
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            }
            if let wt = worktree {
                if wt.status.hasTrackedChanges || wt.status.untracked > 0 {
                    Image(systemName: wt.status.hasTrackedChanges ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                        .help(dirtyHelp(wt))
                }
                if !showTracking {
                    CompactDiff(stat: wt.committedDiff)
                }
                AheadBehindBadge(value: wt.tracking ?? (showTracking ? wt.versusPrimary : nil), showSynced: showTracking)
            }
        }
        .frame(width: Column.status, alignment: .trailing)
    }

    private func dirtyHelp(_ wt: WorktreeInfo) -> String {
        var parts: [String] = []
        if wt.status.staged > 0 { parts.append("\(wt.status.staged) staged") }
        if wt.status.unstaged > 0 { parts.append("\(wt.status.unstaged) modified") }
        if wt.status.untracked > 0 { parts.append("\(wt.status.untracked) untracked") }
        if !wt.uncommittedDiff.isZero {
            parts.append("+\(wt.uncommittedDiff.insertions) −\(wt.uncommittedDiff.deletions) uncommitted")
        }
        return parts.joined(separator: ", ")
    }
}

/// "+2 −1" in green/red.
struct CompactDiff: View {
    let stat: DiffStat

    var body: some View {
        if !stat.isZero {
            HStack(spacing: 3) {
                Text("+\(stat.insertions)").foregroundStyle(.green)
                Text("−\(stat.deletions)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            .help("\(stat.files) file\(stat.files == 1 ? "" : "s") changed vs primary branch")
        }
    }
}

/// Expand/collapse chevron whose click target extends well past the glyph while it still
/// lays out 12 pt wide, so columns stay aligned.
struct DisclosureChevron: View {
    let expanded: Bool
    var font: Font = .caption.weight(.semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .padding(.vertical, -6)
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// Opens in the first launcher on click; the menu lists the others.
struct LaunchIconButton: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        let launchers = model.availableLaunchers
        if let first = launchers.first {
            Menu {
                ForEach(launchers) { launcher in
                    Button("Open in \(launcher.name)") { model.open(path, with: launcher) }
                }
                Divider()
                Button("Copy Path") { copyToPasteboard(path) }
            } label: {
                Image(systemName: "arrow.up.forward.app")
            } primaryAction: {
                model.open(path, with: first)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open in \(first.name) (hold for more)")
        }
    }
}

struct WorktreeContextMenu: View {
    let worktree: WorktreeInfo

    var body: some View {
        OpenInMenu(path: worktree.path)
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.url]) }
        Button("Copy Path") { copyToPasteboard(worktree.path) }
    }
}
