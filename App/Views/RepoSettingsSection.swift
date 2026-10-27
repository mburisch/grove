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
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
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
        Card {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Text("Profile").foregroundStyle(.secondary)) \(Text(settings.profile.label).fontWeight(.semibold))")
                    Text(profileNote(custom)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu("Use Defaults") {
                    Button("Normal Repository") { model.applyDefaults(.normal, to: repo) }
                    Button("Large Repository") { model.applyDefaults(.large, to: repo) }
                    Divider()
                    Button("Automatic (by Size)") { model.applyDefaults(nil, to: repo) }
                }
                .fixedSize()
                .help("Reset every setting below to the defaults for a normal or a large repository")
            }
            CardRow("Auto-fetch") {
                FetchIntervalPicker(repo: repo)
            }
            CardRow("Fetch") {
                // The checkbox sits under the menu it refines.
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("Fetch", selection: binding(settings.fetchScope) { $0.fetchScope = $1 }) {
                        Text("All branches").tag(FetchScope.all)
                        Text("Primary and local branches").tag(FetchScope.primaryAndLocal)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Primary and local branches downloads only \(repo.snapshot?.primaryBranch ?? "the primary branch") "
                          + "and the upstreams of your local branches, instead of every branch on the remote")
                    Toggle("Fetch tags", isOn: binding(settings.fetchTags) { $0.fetchTags = $1 })
                }
            }
            CardRow("Compare") {
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("Compare", selection: binding(settings.compareAllBranches) { $0.compareAllBranches = $1 }) {
                        Text("Recent branches").tag(true)
                        Text("Worktrees only").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Which branches show ahead/behind counts against \(repo.snapshot?.baseRef ?? "the primary branch"). "
                          + "With Worktrees only, other branches are compared when you select them.")
                    Toggle("Count changed lines", isOn: binding(settings.lineCounts) { $0.lineCounts = $1 })
                        .help("Shows +/− line counts; each refresh then runs git diff on every worktree")
                    Toggle("Count untracked files", isOn: binding(settings.countUntracked) { $0.countUntracked = $1 })
                        .help("Off, git status skips looking for untracked files, which in a big checkout without "
                              + "the untracked cache is most of its time. They still show in a worktree's file list.")
                }
            }
            if let tuning = repo.tuning {
                GitTuningRows(repo: repo, tuning: tuning)
            } else {
                CardRow("Git performance") { Text("…").foregroundStyle(.secondary) }
            }
            CardRow("Storage") {
                HStack(spacing: 8) {
                    if let storage = repo.storage {
                        Text(AppModel.describe(storage))
                            .foregroundStyle(storage.needsCleanUp ? .orange : .primary)
                    } else {
                        Text("unknown").foregroundStyle(.secondary)
                    }
                    Button("Clean Up…") { Task { await model.confirmCleanUp(repo) } }
                        .help("Run git gc to repack and drop unreachable data")
                }
            }
            if let prefetch = repo.prefetch, prefetch.scheduled {
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
        .font(.callout)
        .controlSize(.small)
        .disabled(repo.activity != nil)
        .task(id: repo.path) { await model.loadTuning(repo) }
    }

    private func profileNote(_ custom: RepoSettings) -> String {
        (custom.profile == nil ? "Chosen by repository size" : "Set for this repository")
            + (custom.hasOverrides ? ", customized" : "")
    }

    /// Shows the effective value; choosing one stores it as this repository's own setting.
    /// (Git's own settings are in `GitTuningRows`, applied together after a confirmation.)
    private func binding<Value>(_ value: Value, _ set: @escaping (inout RepoSettings, Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { newValue in model.updateSettings(repo) { set(&$0, newValue) } })
    }
}

/// Git's settings for big repositories (`RepoTuning`), one checkbox each. Checking boxes changes
/// nothing yet; Apply… lists the changes and writes them to the repository's config.
private struct GitTuningRows: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState
    let tuning: RepoTuning
    @State private var wanted: Set<RepoTuning.Option> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Git performance").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Suggested") { wanted = tuning.suggested }
                    .disabled(wanted == tuning.suggested)
                    .help("Check the settings without compatibility risks")
                Button("Apply…") { Task { await model.confirmTuning(repo, wanted: wanted) } }
                    .disabled(tuning.changes(to: wanted).isEmpty)
            }
            ForEach(tuning.settings) { setting in
                VStack(alignment: .leading, spacing: 1) {
                    Toggle(isOn: binding(setting.option)) {
                        HStack(spacing: 4) {
                            Text(setting.option.title)
                            if !setting.option.isRecommended {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                    .disabled(setting.unavailable != nil)
                    Text(setting.unavailable ?? setting.option.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                .help("\(setting.option.key): \(setting.current ?? "not set")")
            }
            Divider()
            // A Grove setting, not git's: takes effect right away, no Apply needed.
            VStack(alignment: .leading, spacing: 1) {
                Toggle("Refresh these caches hourly", isOn: Binding(
                    get: { model.config.settings(for: repo.path).refreshIndexCaches == true },
                    set: { on in model.updateSettings(repo) { $0.refreshIndexCaches = on ? true : nil } }
                ))
                .disabled(!tuning.usesIndexCaches)
                Text("Lets Grove's git status save the file system monitor and untracked cache about once an hour, "
                     + "so they stay fresh when you rarely run git yourself. While that status runs, git commands "
                     + "that change the index (commit, checkout, rebase) fail with “index.lock exists”; run them again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .onAppear { wanted = tuning.enabled }
        .onChange(of: tuning) { wanted = tuning.enabled }
    }

    private func binding(_ option: RepoTuning.Option) -> Binding<Bool> {
        Binding(
            get: { wanted.contains(option) },
            set: { on in if on { wanted.insert(option) } else { wanted.remove(option) } }
        )
    }
}
