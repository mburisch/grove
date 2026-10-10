import AppKit
import GroveCore
import SwiftUI

@main
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a status item + window owned by AppDelegate; SwiftUI needs at least one scene.
        // Its only job is the main menu, which is shown while the window is open.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

/// Owns the menu bar item and the main window. Grove is a menu bar app (no Dock icon) while the
/// window is closed, and a regular app (Dock icon, Cmd-Tab, menu bar) while it is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var window: MainWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateStatusItem()
        model.start()
    }

    /// Left click brings the window to the front; right click (or Ctrl-click) shows a small menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            showWindow()
        }
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let fetch = NSMenuItem(title: "Fetch All", action: #selector(fetchAll), keyEquivalent: "")
        fetch.target = self
        menu.addItem(fetch)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Grove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func fetchAll() {
        Task { await model.fetchAll() }
    }

    func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        // A regular app while the window is open, so it is in the Dock and Cmd-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Raised even if macOS declines the activation request (it may, for a click in the menu bar).
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()
    }

    func showSettings() {
        showWindow()
        model.pane = .settings
    }

    /// Back to a menu bar app; hiding hands focus to the app that was in front before.
    private func windowDidClose() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    private func makeWindow() -> MainWindow {
        let host = NSHostingController(rootView: MainView().environment(model))
        // Only the minimum comes from SwiftUI; the user sets the size by resizing.
        host.sizingOptions = [.minSize]
        let window = MainWindow(contentViewController: host)
        window.restoreFrame(on: statusItem?.button?.window?.screen ?? NSScreen.main)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidClose() }
        }
        return window
    }

    /// Menu bar icon: a warning on errors, otherwise the Grove tree with the count of repos behind.
    private func updateStatusItem() {
        withObservationTracking {
            guard let button = statusItem?.button else { return }
            let image = model.hasErrors
                ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Grove")
                : NSImage(named: "MenuBarIcon")
            image?.accessibilityDescription = "Grove"
            image?.isTemplate = true
            button.image = image
            let behind = model.behindTotal
            button.title = behind > 0 && !model.hasErrors ? " \(behind)" : ""
            button.imagePosition = .imageLeading
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }
}

/// The main window. Closing it only hides it; its position and size are remembered across launches.
final class MainWindow: NSWindow {
    static let defaultSize = NSSize(width: 1020, height: 660)
    static let minimumSize = NSSize(width: 860, height: 480)
    private static let autosaveName = "MainWindow"
    /// Content size saved by versions that used a floating panel.
    private static let legacySizeKey = "PanelContentSize"

    convenience init(contentViewController: NSViewController) {
        self.init(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                  backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace]
        isReleasedWhenClosed = false
    }

    /// The saved frame, or the default (or legacy) size centered on `screen` on first launch.
    func restoreFrame(on screen: NSScreen?) {
        if !setFrameUsingName(Self.autosaveName) {
            var size = Self.defaultSize
            if let string = UserDefaults.standard.string(forKey: Self.legacySizeKey) {
                let saved = NSSizeFromString(string)
                size = NSSize(width: max(saved.width, Self.minimumSize.width), height: max(saved.height, Self.minimumSize.height))
            }
            setContentSize(size)
            if let visible = screen?.visibleFrame {
                setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
            }
        }
        // A frame saved on a larger display is shrunk to fit this one.
        if let visible = (self.screen ?? screen)?.visibleFrame,
           frame.width > visible.width || frame.height > visible.height {
            setFrame(frame.intersection(visible), display: false)
        }
        setFrameAutosaveName(Self.autosaveName)
    }

    /// Back to the default size, kept centered on the current position.
    func resetSize() {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        setContentSize(Self.defaultSize)
        setFrameOrigin(NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2))
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

    /// Asks for the location and name of a folder that doesn't exist yet. Nothing is prefilled.
    @MainActor
    static func chooseNewFolder(title: String, prompt: String, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.message = message
        panel.nameFieldLabel = "Folder:"
        panel.nameFieldStringValue = ""
        panel.canCreateDirectories = true
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
