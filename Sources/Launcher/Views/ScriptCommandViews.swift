import AppKit
import SwiftUI

/// Inline argument input shown in the search header when the selected script
/// declares arguments. Reuses KeyHandlingTextField so arrows/Enter/Tab/Esc
/// keep routing through the launcher's key commands while typing an argument.
struct ArgumentTokenField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let index: Int
    let isFocusTarget: Bool
    let focusToken: Int
    let onCommand: (LauncherKeyCommand) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> KeyHandlingTextField {
        let field = KeyHandlingTextField()
        field.delegate = context.coordinator
        field.onCommand = onCommand
        field.onFocus = onFocus
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier("argument.\(index)")
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: KeyHandlingTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        field.onCommand = onCommand
        field.onFocus = onFocus
        context.coordinator.parent = self

        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        guard isFocusTarget else { return }
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ArgumentTokenField
        var lastFocusToken = -1

        init(parent: ArgumentTokenField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let command = LauncherKeyCommand(textCommandSelector: commandSelector) else { return false }
            parent.onCommand(command)
            return true
        }
    }
}

/// Rounded border wrapper giving ArgumentTokenField the Raycast token look.
struct ArgumentTokenBox: View {
    @ObservedObject var model: LauncherModel
    let argument: ScriptArgument
    let index: Int
    let onCommand: (LauncherKeyCommand) -> Void

    var body: some View {
        ArgumentTokenField(
            text: Binding(
                get: { model.argumentValues.indices.contains(index) ? model.argumentValues[index] : "" },
                set: { newValue in
                    guard model.argumentValues.indices.contains(index) else { return }
                    model.argumentValues[index] = newValue
                }
            ),
            placeholder: argument.placeholder,
            index: index,
            isFocusTarget: model.focusTarget == .argument(index),
            focusToken: model.focusToken,
            onCommand: onCommand,
            onFocus: { model.noteFocus(.argument(index)) }
        )
        .frame(width: 108, height: 20)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    model.focusTarget == .argument(index)
                        ? Color.secondary.opacity(0.8)
                        : Color.launcherSeparator.opacity(0.9),
                    lineWidth: 1
                )
        }
    }
}

/// Footer chip showing the active (or just-finished) script run.
struct RunChip: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Button {
            model.toggleRunPalette()
        } label: {
            HStack(spacing: 7) {
                statusIcon
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                if let title = model.scriptRun?.script.title {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                if model.scriptRun?.phase == .running {
                    KeyCap("⌘")
                    KeyCap("T")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.scriptRun?.phase != .running)
        .accessibilityIdentifier("footer.runChip")
        .accessibilityLabel("\(statusText) \(model.scriptRun?.script.title ?? "")")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.scriptRun?.phase {
        case .running, nil:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
                .frame(width: 14, height: 14)
        case .finished(.success):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
        case .finished(.cancelled):
            Image(systemName: "slash.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
        case .finished:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)
        }
    }

    private var statusText: String {
        switch model.scriptRun?.phase {
        case .running, nil: "Running script…"
        case .finished(.success): "Completed"
        case .finished(.cancelled): "Cancelled"
        case let .finished(.failure(exitCode)): "Failed (\(exitCode))"
        case .finished(.failedToStart): "Failed to start"
        }
    }
}

/// ⌘T mini palette anchored bottom-leading while a script runs.
struct RunPalette: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Running script…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Text(model.scriptRun?.script.title ?? "")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Button {
                model.cancelScriptRun()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 20)
                    Text("Cancel Process")
                        .font(.system(size: 16, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.085))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.bottom, 8)
            .accessibilityIdentifier("runPalette.cancel")
        }
        .frame(width: 360)
        .background {
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                .overlay(Color.launcherSurface.opacity(0.56))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.launcherSeparator.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
    }
}

/// Confirmation palette shown before running a needsConfirmation script.
struct ConfirmRunPalette: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Run \"\(model.pendingRun?.script.title ?? "")\"?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            ConfirmPaletteRow(
                title: "Run Script",
                symbol: "play.fill",
                keyCap: "↩",
                highlighted: true,
                identifier: "confirm.run"
            ) {
                model.confirmPendingRun()
            }
            ConfirmPaletteRow(
                title: "Cancel",
                symbol: "xmark",
                keyCap: "Esc",
                highlighted: false,
                identifier: "confirm.cancel"
            ) {
                model.dismissPendingRun()
            }

            Spacer(minLength: 6)
        }
        .frame(width: 360, height: 138)
        .confirmPaletteChrome()
    }
}

/// Confirmation palette shown before deleting a script command's file.
struct ConfirmDeletePalette: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Delete \"\(model.pendingDeletion?.title ?? "")\"?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            ConfirmPaletteRow(
                title: "Delete Script",
                symbol: "trash",
                keyCap: "↩",
                highlighted: true,
                tint: .red,
                identifier: "confirmDelete.delete"
            ) {
                model.confirmPendingDeletion()
            }
            ConfirmPaletteRow(
                title: "Cancel",
                symbol: "xmark",
                keyCap: "Esc",
                highlighted: false,
                identifier: "confirmDelete.cancel"
            ) {
                model.dismissPendingDeletion()
            }

            Spacer(minLength: 6)
        }
        .frame(width: 360, height: 138)
        .confirmPaletteChrome()
    }
}

private struct ConfirmPaletteRow: View {
    let title: String
    let symbol: String
    let keyCap: String
    let highlighted: Bool
    var tint: Color = .primary
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                KeyCap(keyCap)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.primary.opacity(0.085) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .accessibilityIdentifier(identifier)
    }
}

private extension View {
    func confirmPaletteChrome() -> some View {
        background {
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                .overlay(Color.launcherSurface.opacity(0.56))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.launcherSeparator.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
    }
}

/// The ⌘P drawer: terminal-style streamed output beside the results list.
struct ScriptOutputPane: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        if model.isOutputAvailable, let run = model.scriptRun {
            VStack(spacing: 0) {
                header(for: run)
                    .frame(height: LauncherStyle.paneHeaderHeight)

                Divider().opacity(0.65)

                outputScroll(for: run)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The terminal identity lives where the monospace text is;
                    // the drawer itself keeps normal launcher chrome.
                    .background(Color.black.opacity(0.92))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("script.outputPane")
        } else {
            Text("No Output")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("script.outputPane")
        }
    }

    private func header(for run: ScriptRunState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12, weight: .semibold))
            Text(run.script.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.065), in: Capsule())
                .accessibilityIdentifier("script.output.status")
        }
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 14)
    }

    private func outputScroll(for run: ScriptRunState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.output.isEmpty ? "Waiting for output…" : run.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(
                            run.output.isEmpty
                                ? Color.white.opacity(0.45)
                                : Color.white.opacity(0.92)
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("script.output")
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(12)
            }
            .onChange(of: model.scriptRun?.output) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // Also fires when the drawer opens mid-run, landing at the tail.
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var statusText: String {
        switch model.scriptRun?.phase {
        case .running: "Running…"
        case .finished(.success): "Exit 0"
        case let .finished(.failure(exitCode)): "Exit \(exitCode)"
        case .finished(.cancelled): "Cancelled"
        case .finished(.failedToStart): "Failed to start"
        case nil: ""
        }
    }
}
