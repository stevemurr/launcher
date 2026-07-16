import AppKit
import SwiftUI

enum LauncherKeyCommand {
    case moveDown
    case moveUp
    case submit
    case escape
    case toggleActions
    case settings
}

struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onCommand: (LauncherKeyCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> KeyHandlingTextField {
        let field = KeyHandlingTextField()
        field.delegate = context.coordinator
        field.onCommand = onCommand
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .medium)
        field.textColor = .labelColor
        field.placeholderString = "Search applications and settings"
        field.lineBreakMode = .byTruncatingTail
        field.identifier = NSUserInterfaceItemIdentifier("launcher.search")
        field.setAccessibilityIdentifier("launcher.search")
        field.setAccessibilityLabel("Search applications and settings")
        return field
    }

    func updateNSView(_ field: KeyHandlingTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.onCommand = onCommand
        context.coordinator.parent = self

        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
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
    }
}

final class KeyHandlingTextField: NSTextField {
    var onCommand: ((LauncherKeyCommand) -> Void)?

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

        switch event.keyCode {
        case 125:
            onCommand?(.moveDown)
        case 126:
            onCommand?(.moveUp)
        case 36, 76:
            onCommand?(.submit)
        case 53:
            onCommand?(.escape)
        default:
            return false
        }
        return true
    }
}
