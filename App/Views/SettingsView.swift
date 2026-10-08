import AppKit
import GroveCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var newLauncherName = ""
    @State private var newLauncherCommand = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var gitVersion: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Scan Folders") {
                ForEach($model.config.scanRoots) { $root in
                    HStack {
                        Text(root.path.abbreviatingWithTilde)
                        Spacer()
                        Stepper("Depth \(root.depth)", value: $root.depth, in: 1...6)
                            .fixedSize()
                        Button { remove(root: root) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Scan Folder…") {
                        for url in Panels.chooseFolders(multiple: true, prompt: "Add") {
                            let path = url.path.abbreviatingWithTilde
                            if !model.config.scanRoots.contains(where: { $0.path == path }) {
                                model.config.scanRoots.append(ScanRoot(path: path))
                            }
                        }
                        Task { await model.rebuildRepoList() }
                    }
                    Button("Rescan Now") { Task { await model.rebuildRepoList() } }
                }
            }

            Section("Added Repositories") {
                if model.config.repositories.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(model.config.repositories, id: \.self) { path in
                    HStack {
                        Text(path.abbreviatingWithTilde)
                        Spacer()
                        Button {
                            model.config.repositories.removeAll { $0 == path }
                            Task { await model.rebuildRepoList() }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Repository…") {
                    let urls = Panels.chooseFolders(multiple: true, prompt: "Add")
                    if !urls.isEmpty { Task { await model.addRepositories(urls) } }
                }
            }

            if !model.config.excluded.isEmpty {
                Section("Hidden Repositories") {
                    ForEach(model.config.excluded, id: \.self) { path in
                        HStack {
                            Text(path.abbreviatingWithTilde)
                            Spacer()
                            Button("Show") {
                                model.config.excluded.removeAll { $0 == path }
                                Task { await model.rebuildRepoList() }
                            }
                        }
                    }
                }
            }

            let missing = model.config.missingRepositories()
            if !missing.isEmpty {
                Section {
                    ForEach(missing, id: \.self) { path in
                        HStack {
                            Text(path.abbreviatingWithTilde)
                            Spacer()
                            Button("Forget") { forget([path]) }
                        }
                    }
                    Button("Forget All") { forget(missing) }
                } header: {
                    Text("Missing Repositories")
                } footer: {
                    Text("These folders no longer exist. Grove keeps their group and settings in case they come back, e.g. from an unmounted drive. Forget removes them from the settings; nothing on disk is touched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Clone") {
                HStack {
                    TextField("Clone into", text: $model.config.cloneRoot)
                    Button("Choose…") {
                        if let url = Panels.chooseFolders(startingAt: model.config.cloneRoot).first {
                            model.config.cloneRoot = url.path.abbreviatingWithTilde
                            model.clone.destinationRoot = model.config.cloneRoot
                        }
                    }
                }
            }

            Section("Fetching") {
                Picker("Fetch every", selection: $model.config.defaultFetchIntervalMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30, 60, 120, 240], id: \.self) { m in
                        Text(m < 60 ? "\(m) minutes" : "\(m / 60) hour\(m == 60 ? "" : "s")").tag(m)
                    }
                }
                Text("Individual repositories can override this in their detail view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Pause in Low Power Mode", isOn: $model.config.pauseFetchInLowPowerMode)
            }

            Section("Open With") {
                ForEach($model.config.launchers) { $launcher in
                    HStack {
                        Toggle(isOn: $launcher.enabled) { Text(launcher.name) }
                        Spacer()
                        Text(describe(launcher)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if case .command = launcher.kind {
                            Button { model.config.launchers.removeAll { $0.id == launcher.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onMove { model.config.launchers.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("Name", text: $newLauncherName).frame(width: 110)
                    TextField("Command", text: $newLauncherCommand, prompt: Text("e.g. cursor {path}"))
                    Button("Add") {
                        model.config.launchers.append(
                            Launcher(name: newLauncherName, kind: .command(newLauncherCommand))
                        )
                        newLauncherName = ""
                        newLauncherCommand = ""
                    }
                    .disabled(newLauncherName.isEmpty || newLauncherCommand.isEmpty)
                }
                Text("The first enabled launcher is the one-click “Open” action. Drag to reorder. Commands run in a login shell; {path} is the folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                HStack {
                    TextField("git binary", text: $model.config.gitPath, prompt: Text(GitRunner.defaultGitPath))
                    if let gitVersion { Text(gitVersion).font(.caption).foregroundStyle(.secondary) }
                }
                Stepper(value: $model.config.maxParallelGitRuns, in: 1...16) {
                    LabeledContent("Parallel git commands", value: "\(model.config.maxParallelGitRuns)")
                }
                Text("Fetches and status checks beyond this wait their turn. Lower it if git is slow or errors under load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Button("Reset Window Size") {
                    NSApp.windows.compactMap { $0 as? MainPanel }.first?.resetSize()
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.config.gitPath) {
            gitVersion = try? await model.git.output(["--version"], in: URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    private func forget(_ paths: [String]) {
        for path in paths { model.config.forget(repository: path) }
        Task { await model.rebuildRepoList() }
    }

    private func remove(root: ScanRoot) {
        model.config.scanRoots.removeAll { $0.id == root.id }
        Task { await model.rebuildRepoList() }
    }

    private func describe(_ launcher: Launcher) -> String {
        switch launcher.kind {
        case .app(let bundleID):
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil ? "not installed" : "app"
        case .command(let command):
            command
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
