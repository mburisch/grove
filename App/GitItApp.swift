import AppKit
import GitItCore
import SwiftUI

@main
struct GitItApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.hasErrors {
            Image(systemName: "exclamationmark.triangle")
        } else if model.behindTotal > 0 {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                Text("\(model.behindTotal)")
            }
        } else {
            Image(systemName: "arrow.triangle.branch")
        }
    }
}

enum Panels {
    /// Shows an open panel for folders. Activates the app first so the panel is frontmost
    /// (a menu bar app is otherwise in the background).
    @MainActor
    static func chooseFolders(multiple: Bool = false, prompt: String = "Choose", startingAt path: String? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if let path { panel.directoryURL = URL(fileURLWithPath: path.expandingTilde) }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : []
    }
}
