import AppKit
import Carbon
import Combine
import QuickLookUI
import SwiftUI

final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onInterrupt: (() -> Bool)?
    var onReturnToLauncher: (() -> Bool)?
    weak var quickLook: QuickLookController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let meaningfulModifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
        if event.type == .keyDown,
           meaningfulModifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k",
           onReturnToLauncher?() == true {
            return true
        }
        if event.type == .keyDown,
           meaningfulModifiers == .control,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            if onInterrupt?() == true { return true }
        }
        return super.performKeyEquivalent(with: event)
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
        // Only re-key while the launcher is still on screen and its app is active.
        // Closing Quick Look during hide or deactivation must not resurrect or
        // reactivate the launcher.
        if LauncherWindowLifecycle.shouldRekeyLauncher(
            appIsActive: NSApp.isActive,
            launcherIsVisible: isVisible
        ) {
            makeKeyAndOrderFront(nil)
        }
    }
}

enum LauncherWindowLifecycle {
    static func shouldRekeyLauncher(appIsActive: Bool, launcherIsVisible: Bool) -> Bool {
        appIsActive && launcherIsVisible
    }

    static func shouldHideLauncher(
        appIsActive: Bool,
        launcherIsKey: Bool,
        hasAnotherKeyWindow: Bool,
        quickLookIsVisible: Bool
    ) -> Bool {
        guard !launcherIsKey, !quickLookIsVisible else { return false }
        // Native child windows such as NSOpenPanel take key status while the
        // launcher app stays active. Keep the launcher ordered in behind them
        // so AppKit can restore it when the child window closes.
        if appIsActive, hasAnotherKeyWindow { return false }
        return true
    }

    /// The panel frame for a given width, preserving the left edge and shifting
    /// only as much as necessary to keep the panel on `visibleFrame`. Pass the
    /// remembered compact origin when collapsing so an edge-induced shift is
    /// undone; pass nil for `visibleFrame` when the screen is unknown.
    static func panelFrame(
        current: NSRect,
        width: CGFloat,
        preferredOrigin: NSPoint?,
        visibleFrame: NSRect?
    ) -> NSRect {
        var frame = current
        frame.size.width = width
        if let preferredOrigin {
            frame.origin = preferredOrigin
        }
        guard let visibleFrame else { return frame }
        frame.origin.x = min(frame.origin.x, visibleFrame.maxX - width)
        frame.origin.x = max(frame.origin.x, visibleFrame.minX)
        return frame
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = LauncherSettings()
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    private lazy var terminalStore = LauncherTerminalStore()
    private lazy var model = LauncherModel(
        settings: settings,
        isUITesting: isUITesting,
        usesNativeTerminalSessions: true
    )
    private lazy var hotKeyManager = HotKeyManager { [weak self] in
        self?.toggleLauncher()
    }

    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private var terminalStoreObservation: AnyCancellable?
    private let quickLookController = QuickLookController()
    /// Where the panel sat before the output pane pushed it off a screen edge.
    private var compactFrameOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ghostty inherits Launcher's process environment. Remove presentation
        // policy from the launching host before prewarming the user's shell or
        // creating any terminal surface.
        LauncherTerminalConfiguration.sanitizeProcessEnvironment()
        NSApp.setActivationPolicy(isUITesting ? .regular : .accessory)
        // Capture the login shell's environment now: scripts need it, and
        // paying for a cold shell startup here costs nothing visible, whereas
        // paying for it on the first script run would stall the panel.
        ShellEnvironment.shared.prewarm()
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

    func applicationWillTerminate(_ notification: Notification) {
        terminalStore.terminateAll()
        model.terminateRunningProcess()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !isUITesting else { return }
        hideLauncher()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isUITesting else { return }
        // Defer until AppKit has installed the next key window. This lets us
        // distinguish switching to another app from showing one of our own
        // child windows, such as the scripts-folder NSOpenPanel.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            let quickLookIsVisible = QLPreviewPanel.sharedPreviewPanelExists()
                && QLPreviewPanel.shared().isVisible
            let hasAnotherKeyWindow = NSApp.keyWindow.map { $0 !== panel } ?? false
            if LauncherWindowLifecycle.shouldHideLauncher(
                appIsActive: NSApp.isActive,
                launcherIsKey: panel.isKeyWindow,
                hasAnotherKeyWindow: hasAnotherKeyWindow,
                quickLookIsVisible: quickLookIsVisible
            ) {
                self.hideLauncher()
            }
        }
    }

    private func configureModelCallbacks() {
        model.onRequestClose = { [weak self] in self?.hideLauncher() }
        model.onOutputPanePresentationChange = { [weak self] isPresented in
            self?.setOutputPanePresented(isPresented)
        }
        model.onQuickLook = { [weak self] url in self?.quickLookController.toggle(url) }
        model.onCreateNativeTerminalSession = { [weak self] launchInput in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self else { return nil }
            let summary = self.terminalStore.createSession()
            if !launchInput.isEmpty {
                self.terminalStore.session(for: summary.id)?.queueInput(launchInput)
            }
            return summary
        }
        model.onSelectNativeTerminalSession = { [weak self] id in
            dispatchPrecondition(condition: .onQueue(.main))
            return self?.terminalStore.selectSession(id) ?? false
        }
        model.onDeselectNativeTerminalSession = { [weak self] in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.terminalStore.clearSelection()
        }
        model.onCloseNativeTerminalSession = { [weak self] id in
            dispatchPrecondition(condition: .onQueue(.main))
            return self?.terminalStore.closeSession(id) ?? false
        }
        model.onSendNativeTerminalInput = { [weak self] id, input in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let session = self?.terminalStore.session(for: id) else { return false }
            session.queueInput(input)
            return true
        }
        terminalStoreObservation = terminalStore.$summaries.sink { [weak self] summaries in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.model.updateNativeTerminalSessions(summaries)
        }
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
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: LauncherStyle.panelWidth,
                height: LauncherStyle.panelHeight
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onInterrupt = { [weak self] in
            guard let self,
                  !self.model.isShellMode,
                  self.model.hasRunningProcess else { return false }
            self.model.cancelCurrentRun()
            return true
        }
        panel.onReturnToLauncher = { [weak self] in
            guard let self,
                  self.model.screen == .search,
                  self.model.isShellMode else { return false }
            self.model.leaveShellMode()
            return true
        }
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
        panel.onCancel = { [weak model] in
            guard model?.screen != .search || model?.isShellMode != true else { return }
            model?.handleEscape()
        }
        panel.quickLook = quickLookController

        let rootView = LauncherRootView(
            model: model,
            terminalStore: terminalStore
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(
            x: 0,
            y: 0,
            width: LauncherStyle.panelWidth,
            height: LauncherStyle.panelHeight
        )
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
        // Order matters: prepareForPresentation closes the output pane, which
        // synchronously shrinks the frame back to the compact width. Center
        // first and a launcher hidden while expanded stays permanently
        // off-center by half the drawer's growth.
        model.prepareForPresentation(screen: screen)
        positionPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if screen == .search, model.isShellMode {
            terminalStore.selectedSession?.setVisible(true)
            DispatchQueue.main.async { [weak self] in
                _ = self?.terminalStore.selectedSession?.focus()
            }
        }
    }

    private func hideLauncher() {
        // Order out first so ending Quick Look control cannot re-key the launcher.
        panel?.orderOut(nil)
        terminalStore.selectedSession?.setVisible(false)
        quickLookController.dismiss()
        model.prepareForDismissal()
        model.dismissOutputPane()
    }

    /// Grows the panel rightward for the ⌘P output pane, anchoring the left
    /// edge so the search field and results stay put under the user's eye.
    private func setOutputPanePresented(_ isPresented: Bool) {
        guard let panel else { return }
        if isPresented, compactFrameOrigin == nil {
            // A rapid expand → collapse → expand can arrive while AppKit is
            // still animating the first transition. Preserve the original
            // compact target instead of replacing it with an intermediate,
            // edge-shifted frame and causing cumulative lateral drift.
            compactFrameOrigin = panel.frame.origin
        }

        let width = isPresented ? LauncherStyle.expandedPanelWidth : LauncherStyle.panelWidth
        let preferredOrigin = isPresented
            ? (compactFrameOrigin ?? panel.frame.origin)
            : compactFrameOrigin
        let targetFrame = constrainedFrame(for: panel, width: width, preferredOrigin: preferredOrigin)

        guard panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(targetFrame, display: panel.isVisible)
            if !isPresented { compactFrameOrigin = nil }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = LauncherStyle.drawerAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel,
                      !self.model.isPanelExpanded,
                      panel.frame.width == LauncherStyle.panelWidth else { return }
                self.compactFrameOrigin = nil
            }
        }
    }

    private func constrainedFrame(
        for panel: NSPanel,
        width: CGFloat,
        preferredOrigin: NSPoint?
    ) -> NSRect {
        LauncherWindowLifecycle.panelFrame(
            current: panel.frame,
            width: width,
            preferredOrigin: preferredOrigin,
            visibleFrame: panel.screen?.visibleFrame ?? screenContainingPanel(panel)?.visibleFrame
        )
    }

    private func screenContainingPanel(_ panel: NSPanel) -> NSScreen? {
        let midpoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { NSMouseInRect(midpoint, $0.frame, false) }
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
