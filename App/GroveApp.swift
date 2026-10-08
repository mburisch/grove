import AppKit
import GroveCore
import SwiftUI

@main
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a status item + panel owned by AppDelegate; SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item and the panel. A `MenuBarExtra` window is always anchored under its
/// icon and can run off-screen at this size, so the panel is managed by hand and centered instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var panel: MainPanel?
    private var outsideClickMonitor: Any?
    /// When the panel was last hidden. Pressing the menu bar icon takes focus from the panel and
    /// hides it before the icon's action runs on mouse-up, so that click must not reopen it.
    private var lastHide = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateStatusItem()
        model.start()
    }

    /// Left click toggles the panel; right click (or Ctrl-click) shows a small menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let fetch = NSMenuItem(title: "Fetch All", action: #selector(fetchAll), keyEquivalent: "")
        fetch.target = self
        menu.addItem(fetch)
        let groups = model.config.groups
        if !groups.isEmpty {
            let sections = model.config.sections(for: model.repos.map(\.path))
            let ungrouped = sections.last { $0.group == nil }?.repos.count ?? 0
            menu.addItem(.separator())
            for group in groups {
                let item = NSMenuItem(title: "Fetch \(group.name)", action: #selector(fetchGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.id
                item.isEnabled = sections.contains { $0.group?.id == group.id && !$0.repos.isEmpty }
                menu.addItem(item)
            }
            if ungrouped > 0 {
                let item = NSMenuItem(title: "Fetch Ungrouped", action: #selector(fetchGroup(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Grove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func fetchAll() {
        Task { await model.fetchAll() }
    }

    @objc private func fetchGroup(_ sender: NSMenuItem) {
        let group = sender.representedObject as? RepoGroup.ID
        Task { await model.fetch(group: group) }
    }

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else if Date.now.timeIntervalSince(lastHide) > 0.5 {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Center on the screen that holds the menu bar icon (falls back to the main screen).
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // A size saved on a larger display is shrunk to fit this one.
            if panel.frame.width > visible.width || panel.frame.height > visible.height {
                panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(
                    width: min(panel.frame.width, visible.width),
                    height: min(panel.frame.height, visible.height)
                )), display: false)
            }
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()
    }

    private func hidePanel() {
        if panel?.isVisible == true { lastHide = .now }
        panel?.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Clicks in other apps (or on the desktop) close the panel. Global monitors only see events
    /// sent to other applications, so clicks inside our own windows never trigger this.
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideUnlessBusy() }
        }
    }

    /// Hides the panel unless a modal (folder picker) or sheet launched from it is up.
    private func hideUnlessBusy() {
        guard let panel, panel.isVisible, NSApp.modalWindow == nil, panel.attachedSheet == nil,
              !(NSApp.keyWindow is NSOpenPanel) else { return }
        hidePanel()
    }

    private func makePanel() -> MainPanel {
        let host = NSHostingController(rootView: PopoverRoot().environment(model))
        // Only the minimum comes from SwiftUI; the user sets the size by resizing.
        host.sizingOptions = [.minSize]
        let panel = MainPanel(contentViewController: host)
        panel.styleMask = [.titled, .fullSizeContentView, .closable, .resizable]
        panel.setContentSize(MainPanel.savedSize)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // Also hide when focus moves elsewhere (e.g. Cmd-Tab), like a popover.
        let observed: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, panel),
            (NSApplication.didResignActiveNotification, nil),
        ]
        for (name, object) in observed {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                // Deferred so a folder picker opened from the panel is already key when we check.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel, !panel.isKeyWindow || !NSApp.isActive else { return }
                        self.hideUnlessBusy()
                    }
                }
            }
        }
        panel.onClose = { [weak self] in self?.hidePanel() }
        return panel
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

/// Floating panel that can become key (for text fields) and closes on Esc.
/// Its size is remembered across launches.
final class MainPanel: NSPanel {
    var onClose: (() -> Void)?

    static let defaultSize = NSSize(width: 1020, height: 660)
    static let minimumSize = NSSize(width: 860, height: 480)
    private static let sizeKey = "PanelContentSize"

    /// The last size the user resized to, or the default.
    static var savedSize: NSSize {
        guard let string = UserDefaults.standard.string(forKey: sizeKey) else { return defaultSize }
        let size = NSSizeFromString(string)
        return NSSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    convenience init(contentViewController: NSViewController) {
        self.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { note in
            guard let panel = note.object as? NSWindow else { return }
            let size = panel.contentRect(forFrameRect: panel.frame).size
            UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
        }
    }

    /// Back to the default size, kept centered on the current position.
    func resetSize() {
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        setContentSize(Self.defaultSize)
        setFrameOrigin(NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
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
