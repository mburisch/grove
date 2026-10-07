import GitItCore
import SwiftUI

struct RepoRowView: View {
    let repo: RepoState

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(repo.name).fontWeight(.medium).lineLimit(1)
                    if let mode = repo.snapshot?.mode, mode != .full {
                        ModeChip(mode: mode)
                    }
                }
                HStack(spacing: 4) {
                    if let main = repo.mainWorktree, let branch = main.branch,
                       branch != repo.snapshot?.primaryBranch {
                        Text(branch).foregroundStyle(.orange)
                        Text("·")
                    }
                    Text(repo.snapshot?.gitHub?.slug ?? repo.displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if repo.activity != nil {
                ProgressView().controlSize(.small)
            } else if repo.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(repo.lastError ?? "")
            }
            if let main = repo.mainWorktree {
                if main.status.hasTrackedChanges {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Uncommitted changes")
                }
                AheadBehindBadge(value: main.tracking ?? main.versusPrimary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "↓3 ↑1" style counts; shows a check when in sync.
struct AheadBehindBadge: View {
    let value: AheadBehind?
    var showSynced = true

    var body: some View {
        if let value {
            HStack(spacing: 4) {
                if value.behind > 0 {
                    Text("↓\(value.behind)").foregroundStyle(.blue)
                }
                if value.ahead > 0 {
                    Text("↑\(value.ahead)").foregroundStyle(.green)
                }
                if value.isZero && showSynced {
                    Image(systemName: "checkmark").foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .help("\(value.behind) behind, \(value.ahead) ahead")
        }
    }
}

struct ModeChip: View {
    let mode: CheckoutMode

    var body: some View {
        Text(mode.label.lowercased())
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch mode {
        case .full: .secondary
        case .shallow: .purple
        case .blobless: .teal
        }
    }
}

struct DiffStatText: View {
    let stat: DiffStat
    var label: String?

    var body: some View {
        if !stat.isZero {
            HStack(spacing: 4) {
                if let label { Text(label).foregroundStyle(.secondary) }
                Text("\(stat.files) file\(stat.files == 1 ? "" : "s")").foregroundStyle(.secondary)
                Text("+\(stat.insertions)").foregroundStyle(.green)
                Text("−\(stat.deletions)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
        }
    }
}

struct WorkingTreeStatusText: View {
    let status: WorkingTreeStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.conflicted > 0 { Text("\(status.conflicted) conflicted").foregroundStyle(.red) }
            if status.staged > 0 { Text("\(status.staged) staged").foregroundStyle(.green) }
            if status.unstaged > 0 { Text("\(status.unstaged) modified").foregroundStyle(.orange) }
            if status.untracked > 0 { Text("\(status.untracked) untracked").foregroundStyle(.secondary) }
            if status.isClean { Text("clean").foregroundStyle(.tertiary) }
        }
        .font(.caption)
    }
}

extension Date {
    var relative: String { formatted(.relative(presentation: .named)) }
}
