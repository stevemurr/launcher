import AppKit
import SwiftUI

enum LauncherKeyCommand: Equatable {
    case moveDown
    case moveUp
    case submit
    case escape
    case toggleActions
    case settings
    case focusNext
    case focusPrevious
    case toggleRunPalette
    case toggleOutputPane
    case editScript
    case deleteScript
    case openWith
    case quickLook
    case showInFinder
    case copyPath
    case copyScriptContents

    var acceptsKeyRepeat: Bool {
        self == .moveUp || self == .moveDown
    }

    init?(textCommandSelector: Selector) {
        switch textCommandSelector {
        case #selector(NSResponder.moveUp(_:)):
            self = .moveUp
        case #selector(NSResponder.moveDown(_:)):
            self = .moveDown
        default:
            return nil
        }
    }
}

struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    var isFocusTarget = true
    var placeholder = "Search applications and settings"
    var accessibilityLabel = "Search applications and settings"
    var onFocus: (() -> Void)?
    let onCommand: (LauncherKeyCommand) -> Void

    static func contextualAccessibilityLabel(for directory: URL?) -> String {
        guard let directory else { return "Search applications and settings" }
        let path = directory.path
        return "Search files in \(path == "/" ? path : path + "/")"
    }

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
        field.font = .systemFont(ofSize: 20, weight: .medium)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.identifier = NSUserInterfaceItemIdentifier("launcher.search")
        field.setAccessibilityIdentifier("launcher.search")
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    func updateNSView(_ field: KeyHandlingTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        field.setAccessibilityLabel(accessibilityLabel)
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
        var parent: LauncherSearchField
        var lastFocusToken = -1

        init(parent: LauncherSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // While editing, plain arrow keys are consumed by the field editor
        // (caret movement) before they can reach the text field's key
        // handling, so intercept them here and drive the list selection.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let command = LauncherKeyCommand(textCommandSelector: commandSelector) else { return false }
            parent.onCommand(command)
            return true
        }
    }
}

final class KeyHandlingTextField: NSTextField {
    var onCommand: ((LauncherKeyCommand) -> Void)?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override func keyDown(with event: NSEvent) {
        if handle(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        let command: LauncherKeyCommand
        if event.modifierFlags.contains(.command), characters == "k" {
            command = .toggleActions
        } else if event.modifierFlags.contains(.command), characters == "," {
            command = .settings
        } else if event.modifierFlags.contains(.command), characters == "t" {
            command = .toggleRunPalette
        } else if event.modifierFlags.contains(.command), characters == "p" {
            command = .toggleOutputPane
        } else if event.modifierFlags.contains(.command), characters == "e" {
            command = .editScript
        } else if event.modifierFlags.contains(.control), characters == "x" {
            command = .deleteScript
        } else if event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.option),
                  characters == "c" {
            command = .copyScriptContents
        } else if event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.shift),
                  characters == "c" {
            command = .copyPath
        } else if event.modifierFlags.contains(.command), characters == "f" {
            command = .showInFinder
        } else if event.modifierFlags.contains(.command), characters == "y" {
            command = .quickLook
        } else {
            switch event.keyCode {
            case 125: command = .moveDown
            case 126: command = .moveUp
            case 36, 76: command = event.modifierFlags.contains(.command) ? .openWith : .submit
            case 53: command = .escape
            case 48: command = event.modifierFlags.contains(.shift) ? .focusPrevious : .focusNext
            default: return false
            }
        }

        // A held Return/Escape/shortcut must not cascade through multiple UI
        // states after the first event dismisses a confirmation or palette.
        guard !event.isARepeat || command.acceptsKeyRepeat else { return true }
        onCommand?(command)
        return true
    }
}
