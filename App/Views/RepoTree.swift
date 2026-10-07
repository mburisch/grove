import AppKit
import GitItCore
import SwiftUI

/// Column widths shared by repo and worktree rows so paths and status line up.
private enum Column {
    static let path: CGFloat = 210
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
                ForEach(model.filteredRepos) { repo in
                    let linked = repo.snapshot?.worktrees.filter { !$0.isMain } ?? []
                    let expanded = !model.collapsed.contains(repo.path)
                    RepoTreeRow(repo: repo, hasChildren: !linked.isEmpty, expanded: expanded)
                        .tag(Pane.repo(repo.path))
                        .contextMenu { RepoContextMenu(repo: repo) }
                    if expanded {
                        ForEach(linked) { wt in
                            WorktreeTreeRow(repo: repo, worktree: wt)
                                .tag(Pane.worktree(repo: repo.path, path: wt.path))
                                .contextMenu { WorktreeContextMenu(worktree: wt) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
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
            Button {
                if expanded { model.collapsed.insert(repo.path) } else { model.collapsed.remove(repo.path) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.borderless)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)

            HStack(spacing: 5) {
                Text(repo.name).fontWeight(.semibold).lineLimit(1)
                if let branch = main?.branch {
                    Text("(\(branch))")
                        .foregroundStyle(branch == primary ? Color.secondary : Color.orange)
                        .lineLimit(1)
                } else if let main {
                    Text("(\(main.head.prefix(7)))").foregroundStyle(.orange)
                }
                if let mode = repo.snapshot?.mode, mode != .full { ModeChip(mode: mode) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PathText(path: repo.displayPath)

            StatusCell(
                worktree: main,
                activity: repo.activity,
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
            .disabled(repo.activity != nil)
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var fetchHelp: String {
        "Fetch now — " + (repo.lastFetch.map { "last fetched \($0.relative)" } ?? "never fetched")
    }
}

private struct WorktreeTreeRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let worktree: WorktreeInfo

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 12)
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(worktree.branch ?? "detached @ \(worktree.head.prefix(7))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if worktree.isPrunable {
                    Text("missing").font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.leading, Column.indent)
            .frame(maxWidth: .infinity, alignment: .leading)

            PathText(path: worktree.path.abbreviatingWithTilde)

            StatusCell(worktree: worktree, activity: nil, error: nil, showTracking: false, loading: false)

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

private struct PathText: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
            .frame(width: Column.path, alignment: .leading)
    }
}

/// Dirty marker, diff vs primary and ahead/behind, right-aligned.
private struct StatusCell: View {
    let worktree: WorktreeInfo?
    let activity: String?
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
