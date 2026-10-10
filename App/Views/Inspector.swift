import AppKit
import GroveCore
import SwiftUI

/// Right-hand panel: details of the selected repository, worktree or branch.
struct Inspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.pane {
        case .repo(let path):
            if let repo = model.repo(at: path) {
                ScrollView { RepoInspector(repo: repo).padding(14) }.id(path)
            } else {
                Placeholder()
            }
        case .worktree(let path, let wtPath):
            if let repo = model.repo(at: path),
               let wt = repo.snapshot?.worktrees.first(where: { $0.path == wtPath }) {
                ScrollView { WorktreeInspector(repo: repo, worktree: wt).padding(14) }.id(wtPath)
            } else {
                Placeholder()
            }
        case .branch(let path, let name):
            // Gone once it's checked out in a worktree or deleted.
            if let repo = model.repo(at: path),
               let branch = repo.snapshot?.branches.first(where: { $0.name == name && $0.worktreePath == nil }) {
                ScrollView { BranchInspector(repo: repo, branch: branch).padding(14) }.id(AppModel.branchKey(path, name))
            } else {
                Placeholder()
            }
        default:
            Placeholder()
        }
    }
}

private struct Placeholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sidebar.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Select a repository, worktree or branch").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Repository

private struct RepoInspector: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    @State private var showRemoteBranches = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(repo.name).font(.title2.weight(.semibold)).lineLimit(1)
                    if let mode = repo.snapshot?.mode { ModeChip(mode: mode) }
                    Spacer()
                    if let activity = repo.activity {
                        ProgressView().controlSize(.small)
                        Text(activity).font(.caption).foregroundStyle(.secondary)
                    } else if let queued = repo.queued {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(queued).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Button(repo.displayPath) { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
                        .buttonStyle(.link)
                        .help("Reveal in Finder")
                    Spacer()
                    Button { model.showGitOutput(for: repo) } label: {
                        Label("Git Output", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("The git commands run for this repository and what they printed")
                }
            }

            RepoBanners(repo: repo)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Remote").foregroundStyle(.secondary)
                    if let gh = repo.snapshot?.gitHub {
                        Button(gh.slug) { NSWorkspace.shared.open(gh.webURL) }.buttonStyle(.link)
                    } else {
                        Text(repo.snapshot?.remoteURL ?? "none").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                GridRow {
                    Text("Primary").foregroundStyle(.secondary)
                    Text(repo.snapshot?.baseRef ?? "none")
                }
                GridRow {
                    Text("Fetched").foregroundStyle(.secondary)
                    Text(repo.lastFetch?.relative ?? "never")
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button { Task { await model.fetch(repo) } } label: { Label("Fetch", systemImage: "arrow.down.circle") }
                Button { Task { await model.pull(repo) } } label: { Label("Pull", systemImage: "arrow.down.to.line") }
                    .help("Fetch, then fast-forward clean worktrees and branches")
                Spacer()
                ConvertMenu(repo: repo).fixedSize()
            }
            .controlSize(.small)
            .disabled(repo.activity != nil)

            Divider()
            RepoSettingsSection(repo: repo)

            if let main = repo.mainWorktree {
                Divider()
                SectionTitle("Main Checkout")
                WorktreeSummary(repo: repo, worktree: main)
                WorktreeChanges(repo: repo, worktree: main, details: model.details[main.path], primary: repo.snapshot?.baseRef,
                                returnTo: .repo(repo.path))
            }

            if let snapshot = repo.snapshot {
                branchSections(snapshot)
            }

        }
    }

    @ViewBuilder
    private func branchSections(_ snapshot: RepoSnapshot) -> some View {
        let localNames = Set(snapshot.branches.map(\.name))
        let freeBranches = snapshot.branches.filter { $0.worktreePath == nil }
        let remoteOnly = snapshot.remoteBranches.filter { !localNames.contains($0.name) }

        if !freeBranches.isEmpty {
            Divider()
            SectionTitle("Branches without Worktree", count: freeBranches.count)
            ForEach(freeBranches) { branch in
                BranchRow(repo: repo, branch: branch, isPrimary: branch.name == snapshot.primaryBranch)
            }
        }
        if !remoteOnly.isEmpty {
            Divider()
            Button {
                withAnimation { showRemoteBranches.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showRemoteBranches ? "chevron.down" : "chevron.right").font(.caption)
                    SectionTitle("Remote Branches", count: remoteOnly.count)
                }
            }
            .buttonStyle(.plain)
            if showRemoteBranches {
                ForEach(remoteOnly) { branch in
                    RemoteBranchRow(repo: repo, branch: branch)
                }
            }
        }
    }
}

// MARK: - Worktree

private struct WorktreeInspector: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let worktree: WorktreeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(worktree.branch ?? "detached @ \(worktree.head.prefix(8))")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    if repo.activity != nil { ProgressView().controlSize(.small) }
                }
                Text("Worktree of \(repo.name)").font(.caption).foregroundStyle(.secondary)
                Button(worktree.path.abbreviatingWithTilde) {
                    NSWorkspace.shared.activateFileViewerSelecting([worktree.url])
                }
                .buttonStyle(.link)
                .help("Reveal in Finder")
                // On its own line so the path gets the full width.
                Button(role: .destructive) {
                    Task { await model.confirmRemoveWorktree(repo, worktree: worktree) }
                } label: {
                    Label("Remove Worktree…", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(worktree.isLocked || repo.activity != nil)
                .help(worktree.isLocked
                      ? "Locked: unlock it with git worktree unlock first"
                      : "Delete this folder after confirming; the branch is kept")
                if worktree.isLocked { Label("Locked", systemImage: "lock.fill").font(.caption) }
                if worktree.isPrunable {
                    Label("Folder is missing (prunable)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            RepoBanners(repo: repo)
            WorktreeSummary(repo: repo, worktree: worktree)
            WorktreeChanges(repo: repo, worktree: worktree, details: model.details[worktree.path], primary: repo.snapshot?.baseRef,
                            returnTo: .worktree(repo: repo.path, path: worktree.path))
        }
    }
}

// MARK: - Branch

/// A local branch without a worktree, for views that show its files.
/// Where a file list's diffs come from and which page they return to.
struct DiffSource {
    let request: DiffRequest
    let scope: DiffScope
}

struct BranchRef {
    let repo: RepoState
    let name: String
}

/// A local branch without a worktree: the same summary and changes as a worktree, minus the working tree.
private struct BranchInspector: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: BranchInfo

    var body: some View {
        let primary = repo.snapshot?.baseRef
        let details = model.branchDetails[AppModel.branchKey(repo.path, branch.name)]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(branch.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    if repo.activity != nil { ProgressView().controlSize(.small) }
                }
                Text("Branch of \(repo.name) — not checked out in a worktree")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Same spot as "Remove Worktree…" on a worktree's page. The only way Grove creates
                // a worktree: on this click, in a folder the user names.
                Button(action: createWorktree) {
                    Label("Create Worktree…", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(repo.activity != nil)
                .help("Check out \(branch.name) in a new worktree; you choose the folder")
                Button(role: .destructive) {
                    Task { await model.confirmDeleteBranch(repo, branch: branch) }
                } label: {
                    Label("Delete Branch…", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(repo.activity != nil)
                .help("Delete this local branch after confirming; the remote branch is kept")
            }
            RepoBanners(repo: repo)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Upstream").foregroundStyle(.secondary)
                    if branch.upstreamGone {
                        Text("\(branch.upstream ?? "upstream") (gone)").foregroundStyle(.red)
                    } else if let upstream = branch.upstream {
                        HStack(spacing: 6) {
                            Text(upstream)
                            AheadBehindBadge(value: branch.tracking)
                        }
                    } else {
                        Text("none").foregroundStyle(.tertiary)
                    }
                }
                if let primary {
                    GridRow {
                        Text("vs primary").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(primary)
                            AheadBehindBadge(value: branch.versusPrimary)
                        }
                    }
                }
                if let pr = repo.pullRequests[branch.name] {
                    PullRequestGridRow(pr: pr)
                }
                GridRow(alignment: .top) {
                    Text("Last commit").foregroundStyle(.secondary)
                    let head = details?.head ?? branch.commit
                    VStack(alignment: .leading, spacing: 1) {
                        Text(head.subject).lineLimit(2)
                        Text("\(head.sha.prefix(8)) · \(head.author) · \(head.date.relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                if let tracking = branch.tracking, tracking.behind > 0 {
                    Button { Task { await model.fastForward(repo, branch: branch) } } label: {
                        Label("Fast-Forward", systemImage: "arrow.down.to.line")
                    }
                    .disabled(tracking.ahead > 0 || repo.activity != nil)
                    .help(tracking.ahead > 0
                          ? "Diverged from \(branch.upstream ?? "upstream"): \(tracking.ahead) local commits"
                          : "Move \(branch.name) to \(branch.upstream ?? "upstream")")
                }
                Button { copyToPasteboard(branch.name) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
            }
            .controlSize(.small)

            WorktreeChanges(repo: repo, root: repo.path, details: details, primary: primary, aheadCount: branch.versusPrimary?.ahead,
                            returnTo: .branch(repo: repo.path, name: branch.name),
                            branch: BranchRef(repo: repo, name: branch.name))
        }
    }

    private func createWorktree() {
        guard let folder = Panels.chooseNewFolder(
            title: "Create Worktree",
            prompt: "Create",
            message: "Choose where to create the worktree for \(branch.name). Enter a name for a new folder."
        ) else { return }
        Task { await model.createWorktree(repo, branch: branch.name, at: folder) }
    }
}

/// "Pull request  #123 Title [Open]", linking to the pull request on GitHub.
private struct PullRequestGridRow: View {
    let pr: PullRequestInfo

    var body: some View {
        GridRow(alignment: .top) {
            Text("Pull request").foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { NSWorkspace.shared.open(pr.url) } label: {
                    Text("#\(pr.number) \(pr.title)").multilineTextAlignment(.leading).lineLimit(2)
                }
                .buttonStyle(.link)
                .help("Open on GitHub")
                PullRequestStateChip(state: pr.state)
            }
        }
    }
}

/// Tracking info, last commit, and actions for a worktree.
private struct WorktreeSummary: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let worktree: WorktreeInfo

    var body: some View {
        let primary = repo.snapshot?.baseRef
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Upstream").foregroundStyle(.secondary)
                    if let upstream = worktree.upstream {
                        HStack(spacing: 6) {
                            Text(upstream)
                            AheadBehindBadge(value: worktree.tracking)
                        }
                    } else {
                        Text(worktree.branch == nil ? "detached" : "none").foregroundStyle(.tertiary)
                    }
                }
                if let primary {
                    GridRow {
                        Text("vs primary").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(primary)
                            AheadBehindBadge(value: worktree.versusPrimary)
                        }
                    }
                }
                if let pr = worktree.branch.flatMap({ repo.pullRequests[$0] }) {
                    PullRequestGridRow(pr: pr)
                }
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    WorkingTreeStatusText(status: worktree.status)
                }
                if let head = model.details[worktree.path]?.head {
                    GridRow(alignment: .top) {
                        Text("HEAD").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(head.subject).lineLimit(2)
                            Text("\(head.sha.prefix(8)) · \(head.author) · \(head.date.relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                if (worktree.tracking?.behind ?? 0) > 0 {
                    Button { Task { await model.pull(repo, worktree: worktree) } } label: {
                        Label("Pull", systemImage: "arrow.down.to.line")
                    }
                    .disabled(worktree.status.hasTrackedChanges || (worktree.tracking?.ahead ?? 0) > 0 || repo.activity != nil)
                    .help("Fast-forward to \(worktree.upstream ?? "upstream")")
                }
                Button { copyToPasteboard(worktree.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            }
            .controlSize(.small)

            LauncherGrid(path: worktree.path)
        }
    }
}

/// One button per launcher.
private struct LauncherGrid: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        let launchers = model.availableLaunchers
        if !launchers.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(launchers) { launcher in
                    Button { model.open(path, with: launcher) } label: {
                        HStack(spacing: 5) {
                            LauncherIcon(launcher: launcher)
                            Text(launcher.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct LauncherIcon: View {
    let launcher: Launcher

    var body: some View {
        if case .app(let bundleID) = launcher.kind,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "terminal")
        }
    }
}

/// Uncommitted files, commits not on primary, and files changed vs primary.
/// For a branch without a worktree only the committed changes are shown, and files open as
/// read-only copies of the branch's version (see `AppModel.openFile(_:onBranch:in:with:)`).
private struct WorktreeChanges: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    /// The worktree folder; for a branch, the repository.
    let root: String
    let details: WorktreeDetails?
    let primary: String?
    /// Commits ahead of primary when known (the list itself is capped).
    let aheadCount: Int?
    /// The page a file's diff returns to.
    let returnTo: Pane
    /// Set when showing a branch that has no worktree.
    let branch: BranchRef?
    private var hasWorkingTree: Bool { branch == nil }

    init(repo: RepoState, worktree: WorktreeInfo, details: WorktreeDetails?, primary: String?, returnTo: Pane) {
        self.init(repo: repo, root: worktree.path, details: details, primary: primary,
                  aheadCount: worktree.versusPrimary?.ahead, returnTo: returnTo)
    }

    init(repo: RepoState, root: String, details: WorktreeDetails?, primary: String?, aheadCount: Int?,
         returnTo: Pane, branch: BranchRef? = nil) {
        self.repo = repo
        self.returnTo = returnTo
        self.root = root
        self.details = details
        self.primary = primary
        self.aheadCount = aheadCount
        self.branch = branch
    }

    private var diffRequest: DiffRequest {
        DiffRequest(repo: repo.path, target: branch.map { .branch($0.name) } ?? .worktree(root), returnTo: returnTo)
    }

    var body: some View {
        if let details {
            VStack(alignment: .leading, spacing: 14) {
                Button { model.showDiffs(diffRequest) } label: {
                    Label("View Diffs", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(details.uncommitted.isEmpty && details.changedSinceBase.isEmpty)
                .help("Browse the changed files and their diffs")
                if hasWorkingTree {
                    VStack(alignment: .leading, spacing: 4) {
                        FileListHeader(title: "Uncommitted", files: details.uncommitted)
                        if details.uncommitted.isEmpty {
                            EmptyNote("No uncommitted changes")
                        } else {
                            FileTable(root: root, files: details.uncommitted,
                                      diff: DiffSource(request: diffRequest, scope: .uncommitted(worktree: root)))
                        }
                    }
                }
                if primary == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle("Changed vs Base Branch")
                        EmptyNote("Nothing to compare against: no remote primary branch and no local main/master")
                    }
                }
                if let primary {
                    VStack(alignment: .leading, spacing: 4) {
                        FileListHeader(title: "Changed vs \(primary)", files: details.changedSinceBase)
                        Text(hasWorkingTree
                             ? "Since this branch forked from \(primary), including uncommitted changes"
                             : "Since this branch forked from \(primary)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if details.changedSinceBase.isEmpty {
                            EmptyNote("No differences")
                        } else {
                            FileTable(root: root, files: details.changedSinceBase,
                                      diff: DiffSource(request: diffRequest,
                                                       scope: branch.map { .branch(name: $0.name, primaryRef: primary) }
                                                           ?? .sinceBase(worktree: root, primaryRef: primary)),
                                      branch: branch)
                        }
                    }
                }
                if let primary, !details.commitsAhead.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle("Commits not on \(primary)", count: aheadCount ?? details.commitsAhead.count)
                        ForEach(details.commitsAhead, id: \.sha) { commit in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject).lineLimit(1)
                                Text("\(commit.sha.prefix(8)) · \(commit.author) · \(commit.date.relative)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

private struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
    }
}

/// Section title with file count and total +/−.
private struct FileListHeader: View {
    let title: String
    let files: [FileChange]

    var body: some View {
        HStack {
            SectionTitle(title, count: files.count)
            Spacer()
            let ins = files.compactMap(\.insertions).reduce(0, +)
            let del = files.compactMap(\.deletions).reduce(0, +)
            if ins + del > 0 {
                HStack(spacing: 0) {
                    Text("+\(ins)").foregroundStyle(.green).frame(width: FileTable.numberWidth, alignment: .trailing)
                    Text("−\(del)").foregroundStyle(.red).frame(width: FileTable.numberWidth, alignment: .trailing)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                // Row padding (4) + open-button column (16) + spacing (6).
                .padding(.trailing, 26)
            }
        }
    }
}

/// Files as a table: status, path, +lines, −lines, open button (shown on hover).
/// The context menu offers every editor.
private struct FileTable: View {
    static let numberWidth: CGFloat = 46
    let root: String
    let files: [FileChange]
    /// How a clicked file's diff is computed.
    let diff: DiffSource
    /// Set for a branch without a worktree: files open as a read-only copy of the branch's version.
    var branch: BranchRef?
    private let limit = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files.prefix(limit)) { file in
                FileRow(root: root, file: file, diff: diff, branch: branch)
            }
            if files.count > limit {
                Text("… and \(files.count - limit) more").font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let root: String
    let file: FileChange
    let diff: DiffSource
    let branch: BranchRef?
    @State private var hovering = false

    private var absolutePath: String { (root as NSString).appendingPathComponent(file.path) }
    /// A branch's copy is written as text, so binary files on a branch can't be opened.
    private var openable: Bool { !file.isDeleted && (branch == nil || file.insertions != nil) }

    private func open(with editor: Launcher) {
        if let branch {
            Task { await model.openFile(file.path, onBranch: branch.name, in: branch.repo, with: editor) }
        } else {
            model.open(absolutePath, with: editor)
        }
    }

    private func showDiff() {
        model.showDiffs(diff.request, selecting: DiffSelection(file: file, scope: diff.scope))
    }

    var body: some View {
        let editors = model.fileLaunchers
        HStack(spacing: 6) {
            Text(file.status)
                .foregroundStyle(statusColor)
                .frame(width: 12, alignment: .center)
            HStack(spacing: 0) {
                let directory = (file.path as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory + "/").foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(0)
                }
                Text((file.path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .strikethrough(file.isDeleted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let ins = file.insertions, let del = file.deletions {
                    Text(ins > 0 ? "+\(ins)" : "").foregroundStyle(.green)
                        .frame(width: FileTable.numberWidth, alignment: .trailing)
                    Text(del > 0 ? "−\(del)" : "").foregroundStyle(.red)
                        .frame(width: FileTable.numberWidth, alignment: .trailing)
                } else {
                    Text(file.isUntracked ? "new" : "binary").foregroundStyle(.tertiary)
                        .frame(width: FileTable.numberWidth * 2, alignment: .trailing)
                }
            }
            // Space is always reserved so the number columns stay aligned.
            Button {
                if let first = editors.first { open(with: first) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help(editors.first.map { editor in "Open \(branch.map { "\($0.name)'s version " } ?? "")in \(editor.name)" } ?? "")
            .opacity(hovering && openable && !editors.isEmpty ? 1 : 0)
            .disabled(!openable || editors.isEmpty)
            .frame(width: 16)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovering ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Double-click is checked first, so a single click waits briefly before showing the diff.
        .onTapGesture(count: 2) { if openable, let first = editors.first { open(with: first) } }
        .onTapGesture { showDiff() }
        .help(helpText)
        .contextMenu {
            Button("Show Diff") { showDiff() }
            Divider()
            ForEach(editors) { editor in
                Button("Open \(branch.map { "\($0.name)'s Version " } ?? "")in \(editor.name)") {
                    open(with: editor)
                }
            }
            .disabled(!openable)
            if branch == nil {
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
                }
                .disabled(file.isDeleted)
                Button("Copy Path") { copyToPasteboard(absolutePath) }
            }
            Button("Copy Relative Path") { copyToPasteboard(file.path) }
        }
    }

    private var statusColor: Color {
        switch file.status {
        case "A", "?": .green
        case "D": .red
        case "R", "C": .blue
        default: .orange
        }
    }

    private var helpText: String {
        let text = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        return (file.isDeleted ? text + " (deleted)" : text) + "\nClick to show the diff, double-click to open"
    }
}

// MARK: - Shared pieces

private struct RepoBanners: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState

    var body: some View {
        if let error = repo.lastError {
            Banner(text: error, style: .error, action: fix, actionDisabled: repo.activity != nil,
                   onDismiss: { repo.lastError = nil },
                   details: { model.showGitOutput(for: repo, selecting: repo.lastErrorRun.map { .run($0) } ?? .latestProblem) })
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if let message = repo.lastMessage {
            Banner(text: message, style: .info, onDismiss: { repo.lastMessage = nil },
                   details: { model.showGitOutput(for: repo) })
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if repo.showsStorageWarning, let storage = repo.storage {
            Banner(text: "\(AppModel.describe(storage)). Cleaning up can free space and speed up git.",
                   style: .info, action: ("Clean Up…", { Task { await model.confirmCleanUp(repo) } }),
                   actionDisabled: repo.activity != nil, onDismiss: { repo.storageWarningDismissed = true })
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Fetch rejected because tags moved on the remote: offer to overwrite the local copies.
    private var fix: (label: String, perform: () -> Void)? {
        guard !repo.clobberedTags.isEmpty else { return nil }
        let label = repo.clobberedTags.count == 1 ? "Update Tag" : "Update Tags"
        return (label, { Task { await model.updateClobberedTags(repo) } })
    }
}

struct SectionTitle: View {
    let title: String
    var count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct FetchIntervalPicker: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState

    static let options = [0, 5, 15, 30, 60, 240]

    var body: some View {
        let override = model.config.settings(for: repo.path).fetchIntervalMinutes
        let binding = Binding<Int>(
            get: { override ?? -1 },
            set: { model.setFetchInterval($0 < 0 ? nil : $0, for: repo) }
        )
        Picker("Auto-fetch", selection: binding) {
            let profile = model.settings(for: repo).profile
            let fallback = EffectiveRepoSettings.defaults(profile, defaultFetchIntervalMinutes: model.config.defaultFetchIntervalMinutes)
            Text("Default (\(Self.describe(fallback.fetchIntervalMinutes)))").tag(-1)
            Divider()
            ForEach(Self.options, id: \.self) { Text(Self.describe($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }

    static func describe(_ minutes: Int) -> String {
        switch minutes {
        case 0: "off (on demand)"
        case ..<60: "every \(minutes) min"
        default: "every \(minutes / 60) h"
        }
    }
}

private struct BranchRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: BranchInfo
    let isPrimary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isPrimary ? "star" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            // Opens the branch's own page, like selecting it in the tree.
            Button { model.select(.branch(repo: repo.path, name: branch.name)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(branch.name).fontWeight(.medium).lineLimit(1)
                        if branch.upstreamGone {
                            Text("upstream gone").font(.caption).foregroundStyle(.orange)
                        } else {
                            AheadBehindBadge(value: branch.tracking, showSynced: false)
                        }
                    }
                    CommitLine(commit: branch.commit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(branch.name)")
            .contextMenu { BranchContextMenu(repo: repo, branch: branch) }
            Spacer(minLength: 4)
            if let t = branch.tracking, t.behind > 0, t.ahead == 0 {
                IconButton("arrow.down.to.line", help: "Fast-forward to \(branch.upstream ?? "upstream")") {
                    Task { await model.fastForward(repo, branch: branch) }
                }
            }
        }
        .font(.callout)
    }
}

private struct RemoteBranchRow: View {
    let repo: RepoState
    let branch: RemoteBranchInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cloud").foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(branch.name).fontWeight(.medium).lineLimit(1)
                    if let versus = branch.versusPrimary {
                        AheadBehindBadge(value: versus, showSynced: false)
                            .help("vs \(repo.snapshot?.baseRef ?? "primary")")
                    }
                }
                CommitLine(commit: branch.commit)
            }
            Spacer(minLength: 4)
        }
        .font(.callout)
    }
}

private struct CommitLine: View {
    let commit: CommitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(commit.subject).lineLimit(1)
            Text("\(commit.author) · \(commit.date.relative)").lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
