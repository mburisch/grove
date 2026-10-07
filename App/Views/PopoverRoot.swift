import AppKit
import GitItCore
import SwiftUI

struct PopoverRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            if let error = model.configError {
                Banner(text: error, style: .error) { model.configError = nil }
                Divider()
            }
            if let pane = model.pane, pane.isPage {
                Page(title: pane == .clone ? "Clone Repository" : "Settings") {
                    if pane == .clone { CloneView() } else { SettingsView() }
                }
            } else {
                HStack(spacing: 0) {
                    RepoTree()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    Inspector()
                        .frame(width: 380)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(width: 1020, height: 660)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Popover opened: refresh local status if it's a bit stale (local only, no network).
            Task { await model.refreshAll(ifOlderThan: 20) }
        }
    }
}

/// Full-width page (clone, settings) with a back button.
private struct Page<Content: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.pane = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("GitIt").font(.headline)

            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            if !model.isOnline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button { Task { await model.fetchAll() } } label: {
                Label("Fetch All", systemImage: "arrow.down.circle")
            }
            .help("Fetch all repositories")
            Button { Task { await model.pullAll() } } label: {
                Label("Pull All", systemImage: "arrow.down.to.line")
            }
            .help("Fetch and fast-forward all clean checkouts")

            Menu {
                Button("Clone Repository…") { model.pane = .clone }
                Button("Add Local Folder…") {
                    let urls = Panels.chooseFolders(multiple: true, prompt: "Add")
                    if !urls.isEmpty { Task { await model.addRepositories(urls) } }
                }
                Button("New Group") { model.addGroup() }
                Divider()
                Button("Rescan Folders") { Task { await model.rebuildRepoList() } }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add or clone a repository")

            Button { model.pane = model.pane == .settings ? nil : .settings } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("Quit GitIt")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct RepoContextMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState

    var body: some View {
        Button("Fetch") { Task { await model.fetch(repo) } }
        Button("Pull (fast-forward)") { Task { await model.pull(repo) } }
        OpenInMenu(path: repo.path)
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
        if let gh = repo.snapshot?.gitHub {
            Button("Open on GitHub") { NSWorkspace.shared.open(gh.webURL) }
        }
        ConvertMenu(repo: repo)
        MoveToGroupMenu(repo: repo)
        Divider()
        Button("Remove from List") { Task { await model.remove(repo) } }
    }
}

struct MoveToGroupMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState

    var body: some View {
        let current = model.config.groups.first { $0.repos.contains(repo.path) }?.id
        Menu("Move to Group") {
            ForEach(model.config.groups) { group in
                Button {
                    model.moveRepo(repo.path, to: group.id)
                } label: {
                    if group.id == current { Label(group.name, systemImage: "checkmark") } else { Text(group.name) }
                }
                .disabled(group.id == current)
            }
            if !model.config.groups.isEmpty {
                Button("Ungrouped") { model.moveRepo(repo.path, to: nil) }
                    .disabled(current == nil)
                Divider()
            }
            Button("New Group…") { model.addGroup(with: repo) }
        }
    }
}

struct OpenInMenu: View {
    @Environment(AppModel.self) private var model
    let path: String
    var title = "Open In"

    var body: some View {
        Menu(title) {
            ForEach(model.availableLaunchers) { launcher in
                Button(launcher.name) { model.open(path, with: launcher) }
            }
            Divider()
            Button("Copy Path") { copyToPasteboard(path) }
        }
    }
}

struct ConvertMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepoState

    var body: some View {
        let current = repo.snapshot?.mode
        Menu("Checkout Mode") {
            ForEach(CheckoutMode.allCases) { mode in
                Button {
                    Task { await model.convert(repo, to: mode) }
                } label: {
                    if mode == current {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text("Convert to \(mode.label)")
                    }
                }
                .disabled(mode == current)
            }
            if current == .shallow {
                Divider()
                Button("Trim History to Depth \(model.config.settings(for: repo.path).shallowDepth ?? 1)") {
                    Task { await model.convert(repo, to: .shallow) }
                }
            }
        }
        .disabled(repo.snapshot == nil || repo.activity != nil)
    }
}

struct Banner: View {
    enum Style { case error, info }
    let text: String
    let style: Style
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(style == .error ? .red : .blue)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background((style == .error ? Color.red : Color.blue).opacity(0.08))
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
