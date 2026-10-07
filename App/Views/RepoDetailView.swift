import AppKit
import GitItCore
import SwiftUI

struct RepoDetailView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    @State private var showRemoteBranches = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = repo.lastError {
                Banner(text: error, style: .error) { repo.lastError = nil }
            }
            if let message = repo.lastMessage {
                Banner(text: message, style: .info) { repo.lastMessage = nil }
            }
            Divider()
            if let snapshot = repo.snapshot {
                content(snapshot)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(repo.name).font(.title2.weight(.semibold))
                if let mode = repo.snapshot?.mode { ModeChip(mode: mode) }
                Spacer()
                if let activity = repo.activity {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Button(repo.displayPath) { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
                    .buttonStyle(.link)
                    .help("Reveal in Finder")
                if let gh = repo.snapshot?.gitHub {
                    Text("·").foregroundStyle(.secondary)
                    Button(gh.slug) { NSWorkspace.shared.open(gh.webURL) }
                        .buttonStyle(.link)
                        .help("Open on GitHub")
                } else if let url = repo.snapshot?.remoteURL {
                    Text("· \(url)").foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                } else if repo.snapshot != nil {
                    Text("· no remote").foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                if let primary = repo.snapshot?.primaryBranch {
                    Label(primary, systemImage: "star").font(.caption).foregroundStyle(.secondary)
                        .help("Primary branch")
                }
                Text(repo.lastFetch.map { "Fetched \($0.relative)" } ?? "Never fetched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FetchIntervalPicker(repo: repo)
                Spacer()
                Button { Task { await model.fetch(repo) } } label: {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
                Button { Task { await model.pull(repo) } } label: {
                    Label("Pull", systemImage: "arrow.down.to.line")
                }
                .help("Fetch, then fast-forward clean worktrees and branches")
                ConvertMenu(repo: repo).fixedSize()
                OpenInMenu(path: repo.path, title: "Open").fixedSize()
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ snapshot: RepoSnapshot) -> some View {
        let localNames = Set(snapshot.branches.map(\.name))
        let freeBranches = snapshot.branches.filter { $0.worktreePath == nil }
        let remoteOnly = snapshot.remoteBranches.filter { !localNames.contains($0.name) }

        List {
            Section("Worktrees") {
                ForEach(snapshot.worktrees) { wt in
                    WorktreeRow(repo: repo, worktree: wt, primary: snapshot.primaryRemoteRef)
                }
            }
            if !freeBranches.isEmpty {
                Section("Branches") {
                    ForEach(freeBranches) { branch in
                        BranchRow(repo: repo, branch: branch, isPrimary: branch.name == snapshot.primaryBranch)
                    }
                }
            }
            if !remoteOnly.isEmpty {
                Section {
                    if showRemoteBranches {
                        ForEach(remoteOnly) { branch in
                            RemoteBranchRow(repo: repo, branch: branch)
                        }
                    }
                } header: {
                    Button {
                        withAnimation { showRemoteBranches.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showRemoteBranches ? "chevron.down" : "chevron.right")
                            Text("Remote Branches (\(remoteOnly.count))")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
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
        .fixedSize()
        .font(.caption)
    }

    static func describe(_ minutes: Int) -> String {
        switch minutes {
        case 0: "off"
        case ..<60: "\(minutes) min"
        default: "\(minutes / 60) h"
        }
    }
}

// MARK: - Rows

private struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let worktree: WorktreeInfo
    let primary: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: worktree.isMain ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(worktree.branch ?? "detached @ \(worktree.head.prefix(8))")
                        .fontWeight(.medium)
                    if worktree.isLocked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    if worktree.isPrunable { Text("missing").font(.caption).foregroundStyle(.red) }
                }
                Text(worktree.path.abbreviatingWithTilde)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    WorkingTreeStatusText(status: worktree.status)
                    DiffStatText(stat: worktree.uncommittedDiff, label: "uncommitted")
                }
                if let primary {
                    HStack(spacing: 10) {
                        DiffStatText(stat: worktree.committedDiff, label: "vs \(primary)")
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let upstream = worktree.upstream {
                    TrackingLine(label: upstream, value: worktree.tracking)
                } else if worktree.branch != nil {
                    Text("no upstream").font(.caption).foregroundStyle(.tertiary)
                }
                if let primary, worktree.upstream != primary {
                    TrackingLine(label: primary, value: worktree.versusPrimary)
                }
            }
            actions
        }
        .padding(.vertical, 3)
        .contextMenu {
            OpenInMenu(path: worktree.path)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.url]) }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if (worktree.tracking?.behind ?? 0) > 0 {
                Button { Task { await model.pull(repo, worktree: worktree) } } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Fast-forward to upstream")
                .disabled(worktree.status.hasTrackedChanges || (worktree.tracking?.ahead ?? 0) > 0)
            }
            LaunchButton(path: worktree.path)
        }
        .buttonStyle(.borderless)
    }
}

private struct BranchRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: BranchInfo
    let isPrimary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isPrimary ? "star" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name).fontWeight(.medium)
                CommitLine(commit: branch.commit)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if branch.upstreamGone {
                    Text("upstream gone").font(.caption).foregroundStyle(.orange)
                } else if let upstream = branch.upstream {
                    TrackingLine(label: upstream, value: branch.tracking)
                }
                if !isPrimary, let versus = branch.versusPrimary {
                    TrackingLine(label: repo.snapshot?.primaryRemoteRef ?? "primary", value: versus)
                }
            }
            HStack(spacing: 4) {
                if let t = branch.tracking, t.behind > 0, t.ahead == 0 {
                    Button { Task { await model.fastForward(repo, branch: branch) } } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .help("Fast-forward to \(branch.upstream ?? "upstream")")
                }
                WorktreeLaunchMenu(repo: repo, branch: branch.name)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}

private struct RemoteBranchRow: View {
    let repo: RepoState
    let branch: RemoteBranchInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cloud").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name).fontWeight(.medium)
                CommitLine(commit: branch.commit)
            }
            Spacer()
            if let versus = branch.versusPrimary {
                TrackingLine(label: repo.snapshot?.primaryRemoteRef ?? "primary", value: versus)
            }
            WorktreeLaunchMenu(repo: repo, branch: branch.name)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}

private struct CommitLine: View {
    let commit: CommitSummary

    var body: some View {
        HStack(spacing: 4) {
            Text(commit.subject).lineLimit(1)
            Text("· \(commit.author) · \(commit.date.relative)").lineLimit(1).layoutPriority(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct TrackingLine: View {
    let label: String
    let value: AheadBehind?

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if value == nil {
                Text("–").font(.caption).foregroundStyle(.tertiary)
            } else {
                AheadBehindBadge(value: value)
            }
        }
    }
}

/// Primary launcher as a one-click button, with the others in a menu.
private struct LaunchButton: View {
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
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            } primaryAction: {
                model.open(path, with: first)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open in \(first.name)")
        }
    }
}

/// For a branch without a worktree: create one next to the repo and open it.
private struct WorktreeLaunchMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let branch: String

    var body: some View {
        Menu {
            ForEach(model.availableLaunchers) { launcher in
                Button("Create Worktree & Open in \(launcher.name)") {
                    Task { await model.createWorktree(repo, branch: branch, openWith: launcher) }
                }
            }
            Divider()
            Button("Create Worktree") {
                Task { await model.createWorktree(repo, branch: branch, openWith: nil) }
            }
        } label: {
            Image(systemName: "plus.rectangle.on.folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Create a worktree for \(branch)")
        .disabled(repo.activity != nil)
    }
}
