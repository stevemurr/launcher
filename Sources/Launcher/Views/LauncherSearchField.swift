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
    case completeShell(backward: Bool, cursorUTF16: Int)
    case toggleRunPalette
    case toggleOutputPane
    case editScript
    case deleteScript
    case openWith
    case quickLook
    case showInFinder
    case copyPath
    case copyScriptContents
    case interruptRun

    var acceptsKeyRepeat: Bool {
        self == .moveUp || self == .moveDown
    }

    init?(textCommandSelector: Selector) {
        switch textCommandSelector {
        case #selector(NSResponder.moveUp(_:)):
            self = .moveUp
        case #selector(NSResponder.moveDown(_:)):
            self = .moveDown
        case #selector(NSResponder.insertTab(_:)):
            self = .focusNext
        case #selector(NSResponder.insertBacktab(_:)):
            self = .focusPrevious
        default:
            return nil
        }
    }
}

struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    var isFocusTarget = true
    var isSecureEntry = false
    var placeholder = "Search applications and settings"
    var accessibilityLabel = "Search applications and settings"
    var requestedCaretUTF16: Int? = nil
    var caretRequestToken = 0
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
        field.setSecureEntry(isSecureEntry)
        return field
    }

    func updateNSView(_ field: KeyHandlingTextField, context: Context) {
        field.setSecureEntry(isSecureEntry)
        field.replaceTextIfNeeded(text)
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        field.setAccessibilityLabel(accessibilityLabel)
        field.onCommand = onCommand
        field.onFocus = onFocus
        context.coordinator.parent = self

        if context.coordinator.lastCaretRequestToken != caretRequestToken {
            context.coordinator.lastCaretRequestToken = caretRequestToken
            if let requestedCaretUTF16 {
                DispatchQueue.main.async { [weak field] in
                    field?.placeCaret(atUTF16: requestedCaretUTF16)
                }
            }
        }

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
        var lastCaretRequestToken: Int

        init(parent: LauncherSearchField) {
            self.parent = parent
            lastCaretRequestToken = -1
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? KeyHandlingTextField else { return }
            parent.text = field.stringValue

            // The model may normalize a launcher gesture synchronously (most
            // notably consuming the leading `>` that enters Shell mode). A
            // live AppKit field editor otherwise keeps its pre-normalized text
            // until SwiftUI's next update pass, so fast typing can append onto
            // the stale trigger. Reconcile immediately and leave the caret at
            // the end of the model-owned value.
            field.replaceTextIfNeeded(parent.text)
        }

        // While editing, plain arrow keys are consumed by the field editor
        // (caret movement) before they can reach the text field's key
        // handling, so intercept them here and drive the list selection.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let backward: Bool
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                backward = false
            case #selector(NSResponder.insertBacktab(_:)):
                backward = true
            default:
                guard let command = LauncherKeyCommand(textCommandSelector: commandSelector) else {
                    return false
                }
                parent.onCommand(command)
                return true
            }
            parent.onCommand(.completeShell(
                backward: backward,
                cursorUTF16: textView.selectedRange().location
            ))
            return true
        }
    }
}

final class KeyHandlingTextField: NSSecureTextField {
    var onCommand: ((LauncherKeyCommand) -> Void)?
    var onFocus: (() -> Void)?
    private var suppressFocusCallback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setSecureEntry(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setSecureEntry(false)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, !suppressFocusCallback { onFocus?() }
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

    /// `stringValue` alone does not update AppKit's live field editor. Shell
    /// history and completion both replace model-owned text while this field
    /// remains first responder, so keep the editor in sync and place the caret
    /// after the accepted value.
    func replaceTextIfNeeded(_ text: String) {
        let editor = currentEditor() as? NSTextView
        guard stringValue != text || editor?.string != text else { return }
        stringValue = text
        guard let editor, editor.string != text else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func placeCaret(atUTF16 location: Int) {
        guard let editor = currentEditor() as? NSTextView else { return }
        let clamped = max(0, min(location, (editor.string as NSString).length))
        editor.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    /// Changes how AppKit presents this field without replacing the control.
    /// AppKit supplies a secure field editor when needed; text, selection, and
    /// keyboard focus are transferred to it without notifying the focus owner.
    func setSecureEntry(_ isSecureEntry: Bool) {
        guard isSecureEntry != (cell is NSSecureTextFieldCell) else { return }
        guard let previousCell = cell as? NSTextFieldCell else { return }

        let editor = currentEditor() as? NSTextView
        let liveText = editor?.string ?? stringValue
        let selection = (editor?.selectedRange()
            ?? NSRange(location: (liveText as NSString).length, length: 0))
            .clamped(toUTF16Length: (liveText as NSString).length)
        let editingWindow = window
        let wasEditorFirstResponder = editor.map { editingWindow?.firstResponder === $0 } ?? false

        // A secure cell requires AppKit's secure field-editor subclass. End
        // the current editing session before the swap so AppKit can vend the
        // correct editor type when focus is restored. The control itself is
        // never replaced, and the live text/selection are restored below.
        if wasEditorFirstResponder {
            if editingWindow?.makeFirstResponder(nil) != true {
                _ = abortEditing()
            }
        }

        let replacementCell: NSTextFieldCell = isSecureEntry
            ? NSSecureTextFieldCell(textCell: liveText)
            : NSTextFieldCell(textCell: liveText)
        replacementCell.copyPresentation(from: previousCell)
        replacementCell.stringValue = liveText
        cell = replacementCell
        stringValue = liveText

        guard wasEditorFirstResponder, let editingWindow else { return }
        suppressFocusCallback = true
        let restoredFocus = editingWindow.makeFirstResponder(self)
        suppressFocusCallback = false
        guard restoredFocus, let replacementEditor = currentEditor() as? NSTextView else { return }
        replacementEditor.string = liveText
        replacementEditor.setSelectedRange(selection)
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
        } else if event.modifierFlags.contains(.control), characters == "c" {
            command = .interruptRun
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
            case 48:
                let cursor = (currentEditor() as? NSTextView)?.selectedRange().location
                    ?? (stringValue as NSString).length
                command = .completeShell(
                    backward: event.modifierFlags.contains(.shift),
                    cursorUTF16: cursor
                )
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

private extension NSTextFieldCell {
    func copyPresentation(from source: NSTextFieldCell) {
        isEnabled = source.isEnabled
        isContinuous = source.isContinuous
        isEditable = source.isEditable
        isSelectable = source.isSelectable
        isBordered = source.isBordered
        isBezeled = source.isBezeled
        isScrollable = source.isScrollable
        alignment = source.alignment
        wraps = source.wraps
        font = source.font
        controlSize = source.controlSize
        sendsActionOnEndEditing = source.sendsActionOnEndEditing
        baseWritingDirection = source.baseWritingDirection
        lineBreakMode = source.lineBreakMode
        allowsUndo = source.allowsUndo
        truncatesLastVisibleLine = source.truncatesLastVisibleLine
        userInterfaceLayoutDirection = source.userInterfaceLayoutDirection
        usesSingleLineMode = source.usesSingleLineMode
        refusesFirstResponder = source.refusesFirstResponder
        focusRingType = source.focusRingType
        backgroundColor = source.backgroundColor
        drawsBackground = source.drawsBackground
        textColor = source.textColor
        bezelStyle = source.bezelStyle
        placeholderString = source.placeholderString
        if let placeholderAttributedString = source.placeholderAttributedString {
            self.placeholderAttributedString = placeholderAttributedString
        }
    }
}

private extension NSRange {
    func clamped(toUTF16Length length: Int) -> NSRange {
        let location = min(location, length)
        return NSRange(location: location, length: min(self.length, length - location))
    }
}
