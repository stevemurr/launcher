import AppKit
import SwiftUI
import XCTest
@testable import Launcher

final class LauncherViewCommandTests: XCTestCase {
    func testFieldEditorArrowCommandsRouteToLauncherSelection() {
        XCTAssertEqual(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.moveUp(_:))),
            .moveUp
        )
        XCTAssertEqual(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.moveDown(_:))),
            .moveDown
        )
        XCTAssertEqual(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.insertTab(_:))),
            .focusNext
        )
        XCTAssertEqual(
            LauncherKeyCommand(textCommandSelector: #selector(NSResponder.insertBacktab(_:))),
            .focusPrevious
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

    func testLiveFieldEditorTabSelectorsCarryTheUTF16Caret() {
        var text = "echo 😀 /usr/bin/pri suffix"
        var received: [LauncherKeyCommand] = []
        let representable = LauncherSearchField(
            text: Binding(get: { text }, set: { text = $0 }),
            focusToken: 0,
            onCommand: { received.append($0) }
        )
        let coordinator = representable.makeCoordinator()
        let field = KeyHandlingTextField(frame: .zero)
        let editor = NSTextView(frame: .zero)
        editor.string = text
        let caret = ("echo 😀 /usr/bin/pri" as NSString).length
        editor.setSelectedRange(NSRange(location: caret, length: 0))

        XCTAssertTrue(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))
        XCTAssertTrue(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        ))

        XCTAssertEqual(
            received,
            [
                .completeShell(backward: false, cursorUTF16: caret),
                .completeShell(backward: true, cursorUTF16: caret),
            ]
        )
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

    func testShellTabRequestsThenCyclesCompletionCandidates() {
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusNext, isShellMode: true, hasCandidates: false),
            .request(backward: false, cursorUTF16: nil)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusPrevious, isShellMode: true, hasCandidates: false),
            .request(backward: true, cursorUTF16: nil)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusNext, isShellMode: true, hasCandidates: true),
            .move(offset: 1)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(.focusPrevious, isShellMode: true, hasCandidates: true),
            .move(offset: -1)
        )
        XCTAssertEqual(
            ShellCompletionKeyboardAction.resolve(
                .completeShell(backward: false, cursorUTF16: 7),
                isShellMode: true,
                hasCandidates: false
            ),
            .request(backward: false, cursorUTF16: 7)
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
            .completeShell(backward: false, cursorUTF16: 3),
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
