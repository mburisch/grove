import GroveCore
import SwiftUI

/// Per-repository settings that control how much work keeping it current takes, plus storage
/// clean-up. Settings follow the repository's profile (Normal or Large, by default chosen by size)
/// until changed individually.
struct RepoSettingsSection: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    @State private var expanded = false

    var body: some View {
        let settings = model.settings(for: repo)
        let custom = model.config.settings(for: repo.path)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                    SectionTitle("Settings")
                    Spacer()
                    Text(summary(settings, custom)).font(.caption).foregroundStyle(.secondary)
                    if repo.storage?.needsCleanUp == true {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            .help("Storage could use a clean-up")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                grid(settings, custom)
            }
        }
    }

    private func summary(_ settings: EffectiveRepoSettings, _ custom: RepoSettings) -> String {
        var parts = ["\(settings.profile.label) repository" + (custom.hasOverrides ? ", customized" : "")]
        if let storage = repo.storage { parts.append(AppModel.bytes(storage.totalBytes)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func grid(_ settings: EffectiveRepoSettings, _ custom: RepoSettings) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Profile").foregroundStyle(.secondary)
                HStack {
                    Text(profileText(settings, custom))
                    Spacer()
                    Menu("Use Defaults") {
                        Button("Normal Repository") { model.applyDefaults(.normal, to: repo) }
                        Button("Large Repository") { model.applyDefaults(.large, to: repo) }
                        Divider()
                        Button("Automatic (by Size)") { model.applyDefaults(nil, to: repo) }
                    }
                    .fixedSize()
                    .help("Reset every setting below to the defaults for a normal or a large repository")
                }
            }
            GridRow {
                Text("Auto-fetch").foregroundStyle(.secondary)
                FetchIntervalPicker(repo: repo)
            }
            GridRow {
                Text("Fetch").foregroundStyle(.secondary)
                Picker("Fetch", selection: binding(settings.fetchScope) { $0.fetchScope = $1 }) {
                    Text("All branches").tag(FetchScope.all)
                    Text("Primary and local branches").tag(FetchScope.primaryAndLocal)
                }
                .labelsHidden()
                .fixedSize()
                .help("Primary and local branches downloads only \(repo.snapshot?.primaryBranch ?? "the primary branch") "
                      + "and the upstreams of your local branches, instead of every branch on the remote")
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Fetch tags", isOn: binding(settings.fetchTags) { $0.fetchTags = $1 })
            }
            GridRow {
                Text("Compare").foregroundStyle(.secondary)
                Picker("Compare", selection: binding(settings.compareAllBranches) { $0.compareAllBranches = $1 }) {
                    Text("Recent branches").tag(true)
                    Text("Worktrees only").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                .help("Which branches show ahead/behind counts against \(repo.snapshot?.baseRef ?? "the primary branch"). "
                      + "With Worktrees only, other branches are compared when you select them.")
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Count changed lines", isOn: binding(settings.lineCounts) { $0.lineCounts = $1 })
                    .help("Shows +/− line counts; each refresh then runs git diff on every worktree")
            }
            storageRows
        }
        .font(.callout)
        .controlSize(.small)
        .disabled(repo.activity != nil)
    }

    @ViewBuilder
    private var storageRows: some View {
        GridRow {
            Text("Storage").foregroundStyle(.secondary)
            HStack {
                if let storage = repo.storage {
                    Text(AppModel.describe(storage))
                        .foregroundStyle(storage.needsCleanUp ? .orange : .primary)
                } else {
                    Text("unknown").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clean Up…") { Task { await model.confirmCleanUp(repo) } }
                    .help("Run git gc to repack and drop unreachable data")
            }
        }
        if let prefetch = repo.prefetch, prefetch.scheduled {
            GridRow {
                Text("Prefetch").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Background prefetch (git maintenance)", isOn: Binding(
                        get: { prefetch.enabled },
                        set: { enabled in Task { await model.setPrefetch(enabled, for: repo) } }
                    ))
                    Text(prefetch.enabled
                         ? "Downloads every remote branch hourly into refs/prefetch. On busy repositories this piles up pack data."
                         : "Off for this repository; other maintenance tasks still run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func profileText(_ settings: EffectiveRepoSettings, _ custom: RepoSettings) -> String {
        var text = settings.profile.label
        if custom.profile == nil {
            text += " (by size)"
        }
        if custom.hasOverrides { text += ", customized" }
        return text
    }

    /// Shows the effective value; choosing one stores it as this repository's own setting.
    private func binding<Value>(_ value: Value, _ set: @escaping (inout RepoSettings, Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { newValue in model.updateSettings(repo) { set(&$0, newValue) } })
    }
}
