import AppKit
import XCTest
@testable import Launcher

final class LauncherViewCommandTests: XCTestCase {
    // macOS 27 beta's text-input analytics can dereference a deallocated
    // NSSecureTextField editor during XCTest's post-test memory check. This is
    // reproducible with a vanilla NSSecureTextField, so retain the objects used
    // by the live-editor regression test for the lifetime of the test process.
    private static var retainedSecureEditorTestObjects: [AnyObject] = []

    func testFieldEditorArrowCommandsRouteToLauncherSelection() {
        XCTAssertEqual(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.moveUp(_:))),
            .moveUp
        )
        XCTAssertEqual(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.moveDown(_:))),
            .moveDown
        )
        XCTAssertNil(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.moveLeft(_:)))
        )
    }

    func testOnlySelectionMovementAcceptsKeyRepeat() {
        XCTAssertTrue(LauncherKeyCommand.moveUp.acceptsKeyRepeat)
        XCTAssertTrue(LauncherKeyCommand.moveDown.acceptsKeyRepeat)
        XCTAssertFalse(LauncherKeyCommand.submit.acceptsKeyRepeat)
        XCTAssertFalse(LauncherKeyCommand.escape.acceptsKeyRepeat)
        XCTAssertFalse(LauncherKeyCommand.deleteScript.acceptsKeyRepeat)
        XCTAssertFalse(LauncherKeyCommand.toggleActions.acceptsKeyRepeat)
        XCTAssertFalse(LauncherKeyCommand.copyScriptContents.acceptsKeyRepeat)
        XCTAssertFalse(LauncherKeyCommand.interruptRun.acceptsKeyRepeat)
    }

    func testDisplayedCopyScriptShortcutRoutesToItsCommand() throws {
        let field = KeyHandlingTextField(frame: .zero)
        var received: LauncherKeyCommand?
        field.onCommand = { received = $0 }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )

        XCTAssertTrue(field.performKeyEquivalent(with: event))
        XCTAssertEqual(received, .copyScriptContents)
    }

    func testControlCRoutesToProcessInterrupt() throws {
        let field = KeyHandlingTextField(frame: .zero)
        var received: LauncherKeyCommand?
        field.onCommand = { received = $0 }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .capsLock, .function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )

        XCTAssertTrue(field.performKeyEquivalent(with: event))
        XCTAssertEqual(received, .interruptRun)
    }

    func testTabRoutesToTheContextualFocusOrCompletionCommand() throws {
        let field = KeyHandlingTextField(frame: .zero)
        var received: [LauncherKeyCommand] = []
        field.onCommand = { received.append($0) }

        let tab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            )
        )
        let backTab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{19}",
                charactersIgnoringModifiers: "\u{19}",
                isARepeat: false,
                keyCode: 48
            )
        )

        field.keyDown(with: tab)
        field.keyDown(with: backTab)

        XCTAssertEqual(received, [.focusNext, .focusPrevious])
    }

    func testProgrammaticCompletionReplacesTheLiveFieldEditorAndMovesTheCaret() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = KeyHandlingTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 32))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = "git che"
        field.stringValue = "git che"

        field.replaceTextIfNeeded("git checkout ")

        XCTAssertEqual(field.stringValue, "git checkout ")
        XCTAssertEqual(editor.string, "git checkout ")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 13, length: 0))
    }

    func testSecureEntryRedactsAccessibilityValueAndTogglingBackRestoresPlaintext() throws {
        let secret = "super-secret-value"
        let field = KeyHandlingTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        field.stringValue = secret

        XCTAssertFalse(field.cell is NSSecureTextFieldCell)
        XCTAssertEqual(try XCTUnwrap(field.accessibilityValue()), secret)

        field.setSecureEntry(true)

        XCTAssertTrue(field.cell is NSSecureTextFieldCell)
        let redactedValue = try XCTUnwrap(field.accessibilityValue())
        XCTAssertFalse(redactedValue.contains(secret))
        XCTAssertEqual(redactedValue.count, secret.count)
        XCTAssertEqual(
            Set(redactedValue).count,
            1,
            "AppKit should expose one repeated redaction glyph rather than any secret characters"
        )

        field.setSecureEntry(false)

        XCTAssertFalse(field.cell is NSSecureTextFieldCell)
        XCTAssertEqual(field.stringValue, secret)
        XCTAssertEqual(try XCTUnwrap(field.accessibilityValue()), secret)
    }

    func testSecureEntryTogglePreservesControlIdentityCaretFocusPresentationAndCommands() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = KeyHandlingTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 32))
        let expectedFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold)
        let expectedColor = NSColor.systemPurple
        field.font = expectedFont
        field.textColor = expectedColor
        field.placeholderString = "Terminal input"
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = "draft password"

        var focusCount = 0
        field.onFocus = { focusCount += 1 }
        var receivedCommand: LauncherKeyCommand?
        field.onCommand = { receivedCommand = $0 }

        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let initialCell = try XCTUnwrap(field.cell)
        editor.string = "draft password"
        editor.setSelectedRange(NSRange(location: 3, length: 5))

        let fieldIdentity = ObjectIdentifier(field)
        let focusCountBeforeToggling = focusCount
        let interrupt = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )

        field.setSecureEntry(true)

        let secureEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let secureCell = try XCTUnwrap(field.cell)
        XCTAssertEqual(ObjectIdentifier(field), fieldIdentity)
        XCTAssertTrue(window.firstResponder === secureEditor)
        XCTAssertEqual(field.stringValue, "draft password")
        XCTAssertEqual(secureEditor.string, "draft password")
        XCTAssertEqual(secureEditor.selectedRange(), NSRange(location: 3, length: 5))
        let secureEditorAXValue: Any? = secureEditor.accessibilityValue()
        let secureEditorAXText = try XCTUnwrap(accessibilityText(from: secureEditorAXValue))
        XCTAssertFalse(secureEditorAXText.contains("draft password"))
        XCTAssertFalse(secureEditorAXText.isEmpty)
        XCTAssertEqual(field.font, expectedFont)
        XCTAssertEqual(field.textColor, expectedColor)
        XCTAssertEqual(field.placeholderString, "Terminal input")
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.isBezeled)
        XCTAssertFalse(field.drawsBackground)
        XCTAssertEqual(field.focusRingType, .none)
        XCTAssertEqual(field.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(focusCount, focusCountBeforeToggling)
        XCTAssertTrue(field.performKeyEquivalent(with: interrupt))
        XCTAssertEqual(receivedCommand, .interruptRun)
        receivedCommand = nil

        field.setSecureEntry(false)

        let plaintextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(ObjectIdentifier(field), fieldIdentity)
        XCTAssertTrue(window.firstResponder === plaintextEditor)
        XCTAssertEqual(field.stringValue, "draft password")
        XCTAssertEqual(plaintextEditor.string, "draft password")
        XCTAssertEqual(plaintextEditor.selectedRange(), NSRange(location: 3, length: 5))
        let plaintextEditorAXValue: Any? = plaintextEditor.accessibilityValue()
        XCTAssertEqual(accessibilityText(from: plaintextEditorAXValue), "draft password")
        XCTAssertEqual(field.font, expectedFont)
        XCTAssertEqual(field.textColor, expectedColor)
        XCTAssertEqual(focusCount, focusCountBeforeToggling)

        XCTAssertTrue(field.performKeyEquivalent(with: interrupt))
        XCTAssertEqual(receivedCommand, .interruptRun)
        XCTAssertTrue(window.makeFirstResponder(nil))
        Self.retainedSecureEditorTestObjects = [
            window,
            field,
            initialCell,
            editor,
            secureCell,
            secureEditor,
            plaintextEditor,
        ]
    }

    private func accessibilityText(from value: Any?) -> String? {
        if let value = value as? String { return value }
        return (value as? NSAttributedString)?.string
    }

    func testShellTabRequestsThenCyclesCompletionCandidates() {
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusNext, isShellMode: true, hasCandidates: false),
            .request(backward: false)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusPrevious, isShellMode: true, hasCandidates: false),
            .request(backward: true)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusNext, isShellMode: true, hasCandidates: true),
            .move(offset: 1)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusPrevious, isShellMode: true, hasCandidates: true),
            .move(offset: -1)
        )
    }

    func testShellCompletionCandidatesTemporarilyOwnArrowsAndReturn() {
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.moveDown, isShellMode: true, hasCandidates: true),
            .move(offset: 1)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.moveUp, isShellMode: true, hasCandidates: true),
            .move(offset: -1)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.submit, isShellMode: true, hasCandidates: true),
            .accept
        )
        XCTAssertNil(
            ShellCompletionKeyboardAction.resolve(.moveUp, isShellMode: true, hasCandidates: false),
            "without a palette, arrows must remain available to shell history"
        )
        XCTAssertNil(
            ShellCompletionKeyboardAction.resolve(.submit, isShellMode: true, hasCandidates: false),
            "without a palette, Return must execute or send input"
        )
    }

    func testCompletionRoutingNeverStealsKeysOutsideShellMode() {
        for command in [
            LauncherKeyCommand.focusNext,
            .focusPrevious,
            .moveDown,
            .moveUp,
            .submit,
            .escape,
        ] {
            XCTAssertNil(
                ShellCompletionKeyboardAction.resolve(command, isShellMode: false, hasCandidates: true)
            )
        }
    }

    func testShellPrimaryActionReflectsForegroundInputMode() {
        XCTAssertEqual(ShellInputPresentation.primaryActionTitle(for: .idle), "Run Command")
        XCTAssertEqual(ShellInputPresentation.primaryActionTitle(for: .foreground), "Send Input")
    }

    func testPanelRoutesControlCWhenTheSearchFieldDoesNotOwnFocus() throws {
        let panel = LauncherPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        var interruptCount = 0
        panel.onInterrupt = {
            interruptCount += 1
            return true
        }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .capsLock, .function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )

        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertEqual(interruptCount, 1)

        panel.onInterrupt = { false }
        XCTAssertFalse(panel.performKeyEquivalent(with: event), "Control-C should remain available when no process is running")
    }

    func testSearchAccessibilityLabelDescribesFileBrowserDirectory() {
        XCTAssertEqual(
            LauncherSearchField.contextualAccessibilityLabel(
                for: URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
            ),
            "Search files in /Users/example/Documents/"
        )
        XCTAssertEqual(
            LauncherSearchField.contextualAccessibilityLabel(
                for: URL(fileURLWithPath: "/", isDirectory: true)
            ),
            "Search files in /"
        )
        XCTAssertEqual(
            LauncherSearchField.contextualAccessibilityLabel(for: nil),
            "Search applications and settings"
        )
    }
}
