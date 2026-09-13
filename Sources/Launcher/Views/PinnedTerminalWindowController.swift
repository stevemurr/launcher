import AppKit
import SwiftUI

/// Owns only a detached window. The store keeps ownership of the session and
/// its native surface, so closing or reattaching this window never ends a PTY.
@MainActor
final class PinnedTerminalWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    let session: LauncherTerminalSession
    let displayName: String
    @Published private(set) var terminalSize: LauncherTerminalSize
    private let settings: LauncherSettings
    var onClose: (() -> Void)?
    var onUnpin: (() -> Void)?
    var onLauncher: (() -> Void)?
    var onSettings: (() -> Void)?

    init(session: LauncherTerminalSession, displayName: String, size: LauncherTerminalSize,
         frame: NSRect, settings: LauncherSettings) {
        self.session = session
        self.displayName = displayName
        self.terminalSize = size
        self.settings = settings
        let panel = LauncherPanel(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = displayName
        panel.setAccessibilityIdentifier("terminal.window.\(displayName)")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.collectionBehavior = [.managed, .fullScreenAuxiliary]
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setFrame(frame, display: false)
        panel.onTerminalSize = { [weak self] size in
            guard let self else { return false }
            self.resize(to: size)
            return true
        }
        panel.onPinTerminal = { [weak self] in
            guard let self else { return false }
            self.onUnpin?()
            return true
        }
        panel.onReturnToLauncher = { [weak self] in
            guard let self else { return false }
            self.onLauncher?()
            return true
        }
        // Escape and Control-C belong to the terminal even when the window
        // loses focus. Only an explicit close detaches its surface.
        let host = NSHostingView(rootView: PinnedTerminalRootView(controller: self))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func activate() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        session.setVisible(true)
        focusWhenReady()
    }

    func resize(to size: LauncherTerminalSize) {
        guard let window else { return }
        terminalSize = size
        settings.save(terminalSize: size)
        let frame = LauncherWindowLifecycle.terminalFrame(
            standard: window.frame, size: size, visibleFrame: window.screen?.visibleFrame
        )
        if window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = LauncherStyle.terminalResizeAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: window.isVisible)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { focusWhenReady() }
    func windowDidMiniaturize(_ notification: Notification) { session.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) {
        session.setVisible(true)
        focusWhenReady()
    }

    func windowWillClose(_ notification: Notification) {
        session.setVisible(false)
        // Unmount before notifying the launcher, which may immediately mount
        // the same retained view when Command-P reattaches it.
        window?.contentView = nil
        onClose?()
    }

    private func focusWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            _ = self.session.focus()
        }
    }
}

private struct PinnedTerminalRootView: View {
    @ObservedObject var controller: PinnedTerminalWindowController

    var body: some View {
        ShellConsoleView(
            terminalSession: controller.session,
            displayName: controller.displayName,
            terminalSize: controller.terminalSize,
            isPinned: true,
            onResize: { controller.resize(to: $0) },
            onReturnToLauncher: { controller.onLauncher?() },
            onSettings: { controller.onSettings?() },
            onPin: { controller.onUnpin?() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
