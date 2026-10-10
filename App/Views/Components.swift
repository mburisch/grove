import GroveCore
import SwiftUI

/// "↓3 ↑1" style counts; says "in sync" when there are none.
struct AheadBehindBadge: View {
    let value: AheadBehind?
    var showSynced = true
    /// Draws the counts on a tinted capsule, for tree rows.
    var chip = false

    var body: some View {
        if let value {
            if value.isZero {
                if showSynced { Text("in sync").font(.caption).foregroundStyle(.green) }
            } else {
                HStack(spacing: 4) {
                    if value.behind > 0 {
                        Text("↓\(value.behind)").foregroundStyle(.blue)
                    }
                    if value.ahead > 0 {
                        Text("↑\(value.ahead)").foregroundStyle(.green)
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .chipBackground(chip ? .blue : nil)
                .help("\(value.behind) behind, \(value.ahead) ahead")
            }
        }
    }
}

extension View {
    /// Capsule padding and tint; nil leaves the view as it is.
    @ViewBuilder
    func chipBackground(_ tint: Color?) -> some View {
        if let tint {
            padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(tint.opacity(0.15), in: Capsule())
        } else {
            self
        }
    }
}

/// A short label on a tinted capsule, e.g. a branch name or "2 changed".
struct Chip<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.caption)
            .chipBackground(tint)
    }
}

/// Rounded box whose rows are separated by hairlines.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 { Divider() }
                    subview.padding(.vertical, 7)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
    }
}

/// One line of a `Card`: the label on the left, its value on the right.
struct CardRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value.multilineTextAlignment(.trailing)
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
            if status.isClean { Text("No uncommitted changes").foregroundStyle(.secondary) }
        }
        .font(.caption)
    }
}

extension Date {
    var relative: String { formatted(.relative(presentation: .named)) }
}

extension PullRequestInfo.State {
    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// GitHub's colors: green open, gray draft, purple merged, red closed.
    var color: Color {
        switch self {
        case .open: .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
        }
    }
}

/// "Open", "Merged", … on a tinted capsule.
struct PullRequestStateChip: View {
    let state: PullRequestInfo.State

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(state.color.opacity(0.15), in: Capsule())
    }
}

/// "#123" in the pull request's state color, for tree rows; clicking opens it on GitHub.
struct PullRequestBadge: View {
    let pr: PullRequestInfo

    var body: some View {
        Button { NSWorkspace.shared.open(pr.url) } label: {
            Text("#\(pr.number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(pr.state.color)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Pull request #\(pr.number) (\(pr.state.label.lowercased())): \(pr.title) — click to open on GitHub")
    }
}
