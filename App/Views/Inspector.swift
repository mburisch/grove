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
                GridRow {
                    Text("Auto-fetch").foregroundStyle(.secondary)
                    FetchIntervalPicker(repo: repo)
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

            if let main = repo.mainWorktree {
                Divider()
                SectionTitle("Main Checkout")
                WorktreeSummary(repo: repo, worktree: main)
                WorktreeChanges(worktree: main, details: model.details[main.path], primary: repo.snapshot?.baseRef)
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
                if worktree.isLocked { Label("Locked", systemImage: "lock.fill").font(.caption) }
                if worktree.isPrunable {
                    Label("Folder is missing (prunable)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            RepoBanners(repo: repo)
            WorktreeSummary(repo: repo, worktree: worktree)
            WorktreeChanges(worktree: worktree, details: model.details[worktree.path], primary: repo.snapshot?.baseRef)
        }
    }
}

// MARK: - Branch

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
                Button { Task { await model.createWorktree(repo, branch: branch.name, openWith: nil) } } label: {
                    Label("Create Worktree", systemImage: "plus.rectangle.on.folder")
                }
                .disabled(repo.activity != nil)
                .help("Check out \(branch.name) in a new worktree next to the repository")
                Button { copyToPasteboard(branch.name) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
            }
            .controlSize(.small)

            CreateWorktreeLauncherGrid(repo: repo, branch: branch.name)

            WorktreeChanges(root: repo.path, details: details, primary: primary, aheadCount: branch.versusPrimary?.ahead,
                            hasWorkingTree: false)
        }
    }
}

/// One "Create worktree & open" button per launcher, like `LauncherGrid` for a worktree.
private struct CreateWorktreeLauncherGrid: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: String

    var body: some View {
        let launchers = model.availableLaunchers
        if !launchers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create a worktree and open it in").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(launchers) { launcher in
                        Button { Task { await model.createWorktree(repo, branch: branch, openWith: launcher) } } label: {
                            HStack(spacing: 5) {
                                LauncherIcon(launcher: launcher)
                                Text(launcher.name).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.small)
                    }
                }
                .disabled(repo.activity != nil)
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
/// For a branch without a worktree (`hasWorkingTree == false`) only the committed changes are shown,
/// and files can't be opened because that version isn't on disk.
private struct WorktreeChanges: View {
    /// The worktree folder; for a branch, the repository.
    let root: String
    let details: WorktreeDetails?
    let primary: String?
    /// Commits ahead of primary when known (the list itself is capped).
    let aheadCount: Int?
    var hasWorkingTree = true

    init(worktree: WorktreeInfo, details: WorktreeDetails?, primary: String?) {
        self.init(root: worktree.path, details: details, primary: primary, aheadCount: worktree.versusPrimary?.ahead)
    }

    init(root: String, details: WorktreeDetails?, primary: String?, aheadCount: Int?, hasWorkingTree: Bool = true) {
        self.root = root
        self.details = details
        self.primary = primary
        self.aheadCount = aheadCount
        self.hasWorkingTree = hasWorkingTree
    }

    var body: some View {
        if let details {
            VStack(alignment: .leading, spacing: 14) {
                if hasWorkingTree {
                    VStack(alignment: .leading, spacing: 4) {
                        FileListHeader(title: "Uncommitted", files: details.uncommitted)
                        if details.uncommitted.isEmpty {
                            EmptyNote("No uncommitted changes")
                        } else {
                            FileTable(root: root, files: details.uncommitted)
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
                            FileTable(root: root, files: details.changedSinceBase, canOpen: hasWorkingTree)
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
    /// False when the files aren't on disk at this version (a branch without a worktree).
    var canOpen = true
    private let limit = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files.prefix(limit)) { file in
                FileRow(root: root, file: file, canOpen: canOpen)
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
    let canOpen: Bool
    @State private var hovering = false

    private var absolutePath: String { (root as NSString).appendingPathComponent(file.path) }
    private var openable: Bool { canOpen && !file.isDeleted }

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
                if let first = editors.first { model.open(absolutePath, with: first) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help(editors.first.map { "Open in \($0.name)" } ?? "")
            .opacity(hovering && openable && !editors.isEmpty ? 1 : 0)
            .disabled(!openable || editors.isEmpty)
            .frame(width: 16)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovering && openable ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu {
            if canOpen {
                ForEach(editors) { editor in
                    Button("Open in \(editor.name)") { model.open(absolutePath, with: editor) }
                }
                .disabled(file.isDeleted)
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
        return file.isDeleted ? text + " (deleted)" : text
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
    }

    /// Fetch rejected because tags moved on the remote: offer to overwrite the local copies.
    private var fix: (label: String, perform: () -> Void)? {
        guard !repo.clobberedTags.isEmpty else { return nil }
        let label = repo.clobberedTags.count == 1 ? "Update Tag" : "Update Tags"
        return (label, { Task { await model.updateClobberedTags(repo) } })
    }
}

private struct SectionTitle: View {
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

private struct FetchIntervalPicker: View {
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
            Text("Default (\(Self.describe(model.config.defaultFetchIntervalMinutes)))").tag(-1)
            Divider()
            ForEach(Self.options, id: \.self) { Text(Self.describe($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }

    static func describe(_ minutes: Int) -> String {
        switch minutes {
        case 0: "off"
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
            WorktreeLaunchMenu(repo: repo, branch: branch.name)
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
            WorktreeLaunchMenu(repo: repo, branch: branch.name)
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
