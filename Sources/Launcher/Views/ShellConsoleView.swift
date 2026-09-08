import AppKit
import GhosttyTerminal
import SwiftUI

/// Native Ghostty terminal mode. The search editor is deliberately absent:
/// keyboard, mouse, IME, selection, scrollback, and PTY resize all belong to
/// the retained terminal surface.
@MainActor
struct ShellConsoleView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var terminalSession: LauncherTerminalSession
    let displayName: String

    private let chrome = Color(nsColor: LauncherTerminalPalette.chrome)

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: LauncherStyle.headerHeight)

            separator

            LauncherTerminalHost(session: terminalSession)
                .background(Color.black)
                .padding(.horizontal, LauncherStyle.terminalSideBorderWidth)
                .background(chrome)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            separator

            footer
                .frame(height: LauncherStyle.footerHeight)
        }
        .background(chrome)
        .foregroundStyle(Color.white.opacity(0.92))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.console")
        .onDisappear {
            terminalSession.setVisible(false)
        }
        .alert(
            "Paste into terminal?",
            isPresented: pasteAlertIsPresented,
            presenting: terminalSession.pastePrompt
        ) { _ in
            Button("Cancel", role: .cancel) {
                terminalSession.resolvePasteConfirmation(allow: false)
            }
            .keyboardShortcut(.defaultAction)

            Button("Paste") {
                terminalSession.resolvePasteConfirmation(allow: true)
            }
        } message: { prompt in
            Text("Review this paste before sending it to the terminal.\n\n\(prompt.preview)")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 13, weight: .semibold))

            Text(displayName)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("shell.displayName")

            Text(workingDirectoryDisplay)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("shell.workingDirectory")

            Spacer(minLength: 12)

            statusBadge

            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Launcher Settings")
            .accessibilityIdentifier("header.settings")
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch terminalSession.phase {
        case .exited, .failed:
            Button {
                terminalSession.restart()
            } label: {
                Text("Restart")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(terminalSession.startupError ?? "Restart terminal")
            .accessibilityIdentifier("shell.status.restart")

        case .idle, .starting, .ready:
            Text(terminalSession.phase.statusText)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityIdentifier("shell.status")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.leaveShellMode()
            } label: {
                HStack(spacing: 9) {
                    Text("⌘K")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 22)
                        .background(
                            Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                    Text("Launcher")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.52))
            }
            .buttonStyle(.plain)
            .help("Return to Launcher (Command-K)")
            .accessibilityIdentifier("shell.returnToLauncher")

            Spacer()
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
    }

    private var pasteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { terminalSession.pastePrompt != nil },
            set: { isPresented in
                if !isPresented {
                    terminalSession.resolvePasteConfirmation(allow: false)
                }
            }
        )
    }

    private var workingDirectoryDisplay: String {
        let directory = terminalSession.workingDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") {
            return "~" + directory.dropFirst(home.count)
        }
        return directory
    }
}

private enum LauncherTerminalPalette {
    static let chrome = NSColor(
        srgbRed: 0.135,
        green: 0.135,
        blue: 0.145,
        alpha: 1
    )
}

/// Mounts a stable AppKit terminal view without transferring ownership of its
/// surface or PTY to SwiftUI's conditional view hierarchy.
@MainActor
private struct LauncherTerminalHost: NSViewRepresentable {
    let session: LauncherTerminalSession

    final class Coordinator {
        let session: LauncherTerminalSession

        init(session: LauncherTerminalSession) {
            self.session = session
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context _: Context) -> LauncherTerminalContainer {
        let container = LauncherTerminalContainer(terminal: session.makeTerminalView())
        session.setVisible(true)
        DispatchQueue.main.async {
            _ = session.focus()
        }
        return container
    }

    func updateNSView(_ nsView: LauncherTerminalContainer, context _: Context) {
        nsView.needsLayout = true
    }

    static func dismantleNSView(
        _ nsView: LauncherTerminalContainer,
        coordinator: Coordinator
    ) {
        // SwiftUI may build the replacement host before dismantling this one.
        // Only the container that still owns the retained terminal may mark
        // the surface hidden; a stale container must not hide a fresh mount.
        if nsView.detachTerminal() {
            coordinator.session.setVisible(false)
        }
    }
}

@MainActor
private final class LauncherTerminalContainer: NSView {
    private let terminal: TerminalView

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        terminal.removeFromSuperview()
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if terminal.frame.size != bounds.size {
            terminal.setFrameSize(bounds.size)
        }
        if terminal.frame.origin != .zero {
            terminal.setFrameOrigin(.zero)
        }
    }

    @discardableResult
    func detachTerminal() -> Bool {
        guard terminal.superview === self else { return false }
        terminal.removeFromSuperview()
        return true
    }
}
