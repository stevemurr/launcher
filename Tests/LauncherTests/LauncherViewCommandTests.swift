import AppKit
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
