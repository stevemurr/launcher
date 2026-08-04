import AppKit
import SwiftUI

enum LauncherKeyCommand {
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
}

struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    var isFocusTarget = true
    var placeholder = "Search applications and settings"
    var onFocus: (() -> Void)?
    let onCommand: (LauncherKeyCommand) -> Void

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
        field.setAccessibilityLabel("Search applications and settings")
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
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onCommand(.moveUp)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onCommand(.moveDown)
                return true
            default:
                return false
            }
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
        if event.modifierFlags.contains(.command), characters == "k" {
            onCommand?(.toggleActions)
            return true
        }
        if event.modifierFlags.contains(.command), characters == "," {
            onCommand?(.settings)
            return true
        }
        if event.modifierFlags.contains(.command), characters == "t" {
            onCommand?(.toggleRunPalette)
            return true
        }
        if event.modifierFlags.contains(.command), characters == "p" {
            onCommand?(.toggleOutputPane)
            return true
        }
        if event.modifierFlags.contains(.command), characters == "e" {
            onCommand?(.editScript)
            return true
        }
        if event.modifierFlags.contains(.control), characters == "x" {
            onCommand?(.deleteScript)
            return true
        }
        if event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift), characters == "c" {
            onCommand?(.copyPath)
            return true
        }
        if event.modifierFlags.contains(.command), characters == "f" {
            onCommand?(.showInFinder)
            return true
        }
        if event.modifierFlags.contains(.command), characters == "y" {
            onCommand?(.quickLook)
            return true
        }

        switch event.keyCode {
        case 125:
            onCommand?(.moveDown)
        case 126:
            onCommand?(.moveUp)
        case 36, 76:
            onCommand?(event.modifierFlags.contains(.command) ? .openWith : .submit)
        case 53:
            onCommand?(.escape)
        case 48:
            onCommand?(event.modifierFlags.contains(.shift) ? .focusPrevious : .focusNext)
        default:
            return false
        }
        return true
    }
}
