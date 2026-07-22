import AppKit
import Carbon
import QuickLookUI
import SwiftUI

final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?
    weak var quickLook: QuickLookController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLook
        panel.delegate = quickLook
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        // Re-key the launcher when the preview closes so the normal
        // hide-on-resign behavior resumes afterwards.
        // Only re-key the launcher if it is still on screen. If the user dismissed
        // it (orderOut) while Quick Look was up, isVisible is false and we must not
        // resurrect it.
        if isVisible {
            makeKeyAndOrderFront(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = LauncherSettings()
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    private lazy var model = LauncherModel(settings: settings, isUITesting: isUITesting)
    private lazy var hotKeyManager = HotKeyManager { [weak self] in
        self?.toggleLauncher()
    }

    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private let quickLookController = QuickLookController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(isUITesting ? .regular : .accessory)
        configureModelCallbacks()
        createPanel()
        if !isUITesting {
            configureStatusItem()
            registerInitialHotKey()
        }
        model.loadApplications()
        showLauncher(screen: .search)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isUITesting else { return }
        // Keep the launcher visible while the Quick Look panel has key status.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        panel?.orderOut(nil)
    }

    private func configureModelCallbacks() {
        model.onRequestClose = { [weak self] in self?.hideLauncher() }
        model.onQuickLook = { [weak self] url in self?.quickLookController.toggle(url) }
        model.onHotKeyChange = { [weak self] newHotKey in
            guard let self else { return false }
            if self.isUITesting { return true }

            let previousHotKey = self.settings.hotKey
            let status = self.hotKeyManager.register(newHotKey)
            guard status == noErr else {
                _ = self.hotKeyManager.register(previousHotKey)
                return false
            }
            return true
        }
    }

    private func createPanel() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 774, height: 512),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Launcher"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-dark") {
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        panel.onCancel = { [weak model] in model?.handleEscape() }
        panel.quickLook = quickLookController

        let rootView = LauncherRootView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 774, height: 512)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Launcher")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Launcher", action: #selector(showLauncherFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Launcher", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func registerInitialHotKey() {
        let status = hotKeyManager.register(settings.hotKey)
        if status != noErr {
            settings.hotKeyError = "That shortcut is already used by another application."
        }
    }

    private func toggleLauncher() {
        if panel?.isVisible == true {
            hideLauncher()
        } else {
            showLauncher(screen: .search)
        }
    }

    private func showLauncher(screen: LauncherScreen) {
        guard let panel else { return }
        model.prepareForPresentation(screen: screen)
        positionPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func hideLauncher() {
        panel?.orderOut(nil)
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    @objc private func showLauncherFromMenu() {
        showLauncher(screen: .search)
    }

    @objc private func showSettingsFromMenu() {
        showLauncher(screen: .settings)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
