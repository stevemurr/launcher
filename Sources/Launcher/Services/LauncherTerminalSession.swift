import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import SwiftUI

enum LauncherTerminalPhase: Equatable {
    case idle
    case starting
    case ready
    case exited
    case failed(String)

    var statusText: String {
        switch self {
        case .idle, .starting: "Starting…"
        case .ready: "Ready"
        case .exited: "Exited"
        case .failed: "Unavailable"
        }
    }
}

struct LauncherTerminalPastePrompt: Identifiable {
    let id = UUID()
    let preview: String

    init(contents: String) {
        let maximumPreviewCharacters = 600
        if contents.count > maximumPreviewCharacters {
            preview = String(contents.prefix(maximumPreviewCharacters)) + "\n…"
        } else {
            preview = contents
        }
    }
}

/// Launcher-owned Ghostty configuration. User Ghostty configuration is not
/// loaded, so the embedded surface remains visually stable and reserves the
/// launcher's one terminal-mode shortcut.
enum LauncherTerminalConfiguration {
    static func base(shell: String = loginShell()) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withCustom("command", "direct:\(shell) -l")
            builder.withCustom("term", "xterm-256color")
            builder.withCustom("shell-integration", "detect")
            builder.withCustom("copy-on-select", "false")
            builder.withCustom("clipboard-read", "deny")
            builder.withCustom("clipboard-write", "deny")
            builder.withCustom("clipboard-paste-protection", "true")
            builder.withCustom("scrollbar", "never")
            builder.withCustom("notify-on-command-finish", "never")
            builder.withCustom("keybind", "super+k=unbind")
        }
    }

    static func appearance() -> TerminalConfiguration {
        TerminalConfiguration(startingFrom: .default) { builder in
            builder.withFontSize(14)
            builder.withWindowPaddingX(18)
            builder.withWindowPaddingY(16)
        }
    }

    static func theme() -> TerminalTheme {
        let graphite = TerminalConfiguration.afterglow
            .background("#000000")
            .foreground("#E7E7EA")
            .cursorColor("#0A84FF")
            .cursorText("#FFFFFF")
            .selectionBackground("#263A57")
            .selectionForeground("#FFFFFF")
        return TerminalTheme(light: graphite, dark: graphite)
    }

    /// Keep presentation policy from the process that launched Launcher out
    /// of its interactive shells. Ghostty correctly inherits the host
    /// environment, so a development host's `NO_COLOR` would otherwise disable
    /// color in Claude, Codex, and other terminal programs. A user's shell
    /// startup files run later and may still intentionally set it.
    static func sanitizeProcessEnvironment() {
        unsetenv("NO_COLOR")
    }

    static func loginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        let candidate = environment["SHELL"] ?? "/bin/zsh"
        guard candidate.hasPrefix("/"),
              !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !candidate.unicodeScalars.contains(where: CharacterSet.whitespaces.contains),
              fileManager.isExecutableFile(atPath: candidate) else {
            return "/bin/zsh"
        }
        return candidate
    }
}

/// Owns one persistent native terminal session retained by Launcher.
///
/// The AppKit terminal view is retained even while SwiftUI displays normal
/// launcher results. Detaching therefore pauses rendering without discarding
/// the Ghostty grid, scrollback, or PTY. Explicit termination happens only
/// when the user closes that shell or Launcher itself shuts down.
@MainActor
final class LauncherTerminalSession: ObservableObject,
    TerminalSurfaceTitleDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    @Published private(set) var phase: LauncherTerminalPhase = .idle
    @Published private(set) var title = ""
    @Published private(set) var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var pastePrompt: LauncherTerminalPastePrompt?

    private var terminalView: TerminalView?
    private var controller: TerminalController?
    private var pendingClipboardRequest: TerminalClipboardConfirmationRequest?
    private var pendingInput = ""
    private var hasAttachedSurface = false
    private var isVisible = false
    private var isTerminated = false
    private var surfaceGeneration: UInt = 0

    var startupError: String? {
        guard case let .failed(message) = phase else { return nil }
        return message
    }

    func makeTerminalView() -> TerminalView {
        if let terminalView { return terminalView }

        let view = TerminalView(frame: .zero)
        view.delegate = self
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityIdentifier("launcher.terminal.surface")
        view.setAccessibilityLabel("Terminal")
        terminalView = view
        createSurface(in: view)
        return view
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        terminalView?.setSurfaceVisible(visible)
        if visible {
            terminalView?.fitToSize()
        } else {
            resolvePasteConfirmation(allow: false)
        }
    }

    @discardableResult
    func focus() -> Bool {
        guard isVisible, !isTerminated,
              let terminalView, let window = terminalView.window else {
            return false
        }
        return window.makeFirstResponder(terminalView)
    }

    func queueInput(_ text: String) {
        guard !text.isEmpty else { return }
        guard phase == .ready, hasAttachedSurface, let terminalView else {
            pendingInput += text
            return
        }
        terminalView.sendText(text)
    }

    func restart() {
        guard !isTerminated, let terminalView else { return }
        resolvePasteConfirmation(allow: false)
        terminalView.controller = nil
        controller = nil
        hasAttachedSurface = false
        createSurface(in: terminalView)
        terminalView.setSurfaceVisible(isVisible)
        terminalView.fitToSize()
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        surfaceGeneration &+= 1
        resolvePasteConfirmation(allow: false)
        isVisible = false
        terminalView?.setSurfaceVisible(false)
        terminalView?.controller = nil
        terminalView?.delegate = nil
        controller = nil
        hasAttachedSurface = false
        pendingInput = ""
        phase = .exited
    }

    func resolvePasteConfirmation(allow: Bool) {
        let request = pendingClipboardRequest
        pendingClipboardRequest = nil
        pastePrompt = nil
        request?.respond(allow: allow)
    }

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path
    }

    func terminalDidClose(processAlive _: Bool) {
        guard !isTerminated else { return }
        resolvePasteConfirmation(allow: false)
        hasAttachedSurface = false
        phase = .exited
    }

    func terminalDidAttachSurface(_: TerminalSurface) {
        hasAttachedSurface = true
        phase = .ready
        terminalView?.setSurfaceVisible(isVisible)
        guard !pendingInput.isEmpty else { return }
        let input = pendingInput
        pendingInput = ""
        terminalView?.sendText(input)
    }

    func terminalDidDetachSurface() {
        hasAttachedSurface = false
    }

    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        guard isVisible, !isTerminated else {
            request.respond(allow: false)
            return
        }
        guard pendingClipboardRequest == nil else {
            request.respond(allow: false)
            return
        }

        switch request.kind {
        case .paste:
            pendingClipboardRequest = request
            pastePrompt = LauncherTerminalPastePrompt(contents: request.contents)
        case .osc52Read, .osc52Write:
            request.respond(allow: false)
        }
    }

    private func createSurface(in view: TerminalView) {
        guard !isTerminated else { return }
        surfaceGeneration &+= 1
        let generation = surfaceGeneration
        guard GhosttyRuntimeResources.directoryURL != nil,
              GhosttyRuntimeResources.terminfoDirectoryURL != nil else {
            phase = .failed("Ghostty’s bundled terminal resources are missing.")
            return
        }

        phase = .starting
        let nextController = TerminalController(
            configSource: .generated(LauncherTerminalConfiguration.base().rendered),
            theme: LauncherTerminalConfiguration.theme(),
            terminalConfiguration: LauncherTerminalConfiguration.appearance()
        )
        if let issue = nextController.lastConfigurationIssue {
            phase = .failed(issue)
            return
        }

        let directory = validatedWorkingDirectory()
        workingDirectory = directory
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: directory
        )
        controller = nextController
        view.controller = nextController
        scheduleStartupCheck(for: view, generation: generation)
    }

    /// Ghostty cannot report a failed native-surface allocation through its
    /// delegate. Give the mounted view one final resize pass, then expose a
    /// recoverable failure instead of leaving the launcher at “Starting…”.
    private func scheduleStartupCheck(for view: TerminalView, generation: UInt) {
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let view,
                  self.surfaceGeneration == generation,
                  self.terminalView === view,
                  self.phase == .starting,
                  !self.hasAttachedSurface,
                  view.window != nil else {
                return
            }

            view.fitToSize()
            await Task.yield()

            guard self.surfaceGeneration == generation,
                  self.phase == .starting,
                  !self.hasAttachedSurface else {
                return
            }
            self.phase = .failed("Ghostty could not create the terminal surface.")
        }
    }

    private func validatedWorkingDirectory() -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return workingDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
