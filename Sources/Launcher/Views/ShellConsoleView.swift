import AppKit
import SwiftUI

/// Full-width terminal-style body shown while Shell mode is active. Output is
/// normalized for display, while foreground programs can receive line-oriented
/// input through the launcher's persistent search field.
struct ShellConsoleView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: LauncherStyle.paneHeaderHeight)

            Divider()
                .overlay(Color.white.opacity(0.16))

            output
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .background(Color.black.opacity(0.94))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.console")
        .onChange(of: statusText) { oldValue, newValue in
            guard oldValue != newValue else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Shell status: \(newValue)",
                    .priority: NSAccessibilityPriorityLevel.low.rawValue,
                ]
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12, weight: .semibold))
            Text("Shell")
                .font(.system(size: 13, weight: .semibold))
            Text(model.shellWorkingDirectoryDisplay)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("shell.workingDirectory")
                .accessibilityLabel("Shell working directory")
                .accessibilityValue(model.shellWorkingDirectoryDisplay)

            Spacer(minLength: 8)

            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.09), in: Capsule())
                .accessibilityIdentifier("shell.output.status")
                .accessibilityLabel("Shell status")
                .accessibilityValue(statusText)
        }
        .padding(.horizontal, 14)
        .background(Color.black.opacity(0.18))
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(outputForeground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("shell.output")
                        // A selectable SwiftUI Text can leave its bridged
                        // AppKit accessibility value frozen at the string it
                        // had when the element was created. Publish the live
                        // transcript explicitly so VoiceOver and UI automation
                        // receive streamed updates too.
                        .accessibilityLabel("Shell output")
                        .accessibilityValue(outputText)

                    Color.clear
                        .frame(height: 1)
                        .id("shell.bottom")
                }
                .padding(14)
            }
            .onChange(of: model.shellRun?.output) { _, _ in
                proxy.scrollTo("shell.bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("shell.bottom", anchor: .bottom)
            }
        }
    }

    private var outputText: String {
        guard let run = model.shellRun else {
            if model.scriptRun?.phase == .running {
                return "Another process is running. Stop it before running a shell command."
            }
            return "Type a command above and press Return."
        }
        return run.output.isEmpty ? "Waiting for output…" : run.output
    }

    private var outputForeground: Color {
        model.shellRun == nil ? Color.white.opacity(0.48) : Color.white.opacity(0.92)
    }

    private var statusText: String {
        guard let phase = model.displayedRunPhase else { return "Ready" }
        return switch phase {
        case .running: "Running…"
        case .finished(.success): "Exit 0"
        case let .finished(.failure(exitCode)): "Exit \(exitCode)"
        case .finished(.cancelled): "Cancelled"
        case .finished(.failedToStart): "Failed to start"
        }
    }

    private var statusColor: Color {
        switch model.displayedRunPhase {
        case .finished(.success): .green
        case .finished(.failure), .finished(.failedToStart): .red
        case .finished(.cancelled): Color.white.opacity(0.55)
        case .running, nil: Color.white.opacity(0.72)
        }
    }
}
