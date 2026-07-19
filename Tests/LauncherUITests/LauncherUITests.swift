import XCTest

final class LauncherUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if name.contains("testDarkAppearance") {
            app.launchArguments.append("--ui-testing-dark")
        }
        app.launch()

        XCTAssertTrue(
            app.textFields["launcher.search"].waitForExistence(timeout: 8),
            "Launcher search field did not appear"
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testSearchShowsApplicationsAndActions() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("activity")

        let applicationResult = app.buttons["result.Activity Monitor"]
        XCTAssertTrue(applicationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(applicationResult.label.contains("Application"))

        app.buttons["footer.actions"].click()
        XCTAssertTrue(app.buttons["action.open"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["action.showInFinder"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Application search and actions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Pressing Return on the calculator copies the answer and hides the panel.
    // That behavior lives in unit tests (LauncherModelCalculatorTests): the
    // hidden panel keeps its cached accessibility tree, and macOS pasteboard
    // privacy blocks reading another app's clipboard, so neither dismissal nor
    // the copied text is observable from a UI test.
    func testCalculatorShowsAnswer() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("5+5")

        let card = app.buttons["calculator.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertTrue(card.label.contains("10"))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Calculator result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Keyboard-driven on purpose: moving the mouse across result rows changes
    // the hover selection, which reflows the footer and races XCUITest's
    // find-then-click coordinates.
    func testScriptCommandRunsWithStreamedOutput() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("count")

        let result = app.buttons["result.Count Lines"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertTrue(result.label.contains("Script Command"))

        // .return (the main Return key, keyCode 36) — the keypad .enter (⌤)
        // routes through the panel's cancel path on this macOS build and never
        // reaches the search field's key handler.
        search.typeKey(.return, modifierFlags: [])

        let chip = app.buttons["footer.runChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        // The ~1 s fixture can finish before the first label read, so accept
        // either live state here; the strict "Completed" wait comes below.
        XCTAssertTrue(chip.label.contains("Running") || chip.label.contains("Completed"))

        search.typeKey("o", modifierFlags: [.command])
        let output = app.descendants(matching: .any)["script.output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 3))

        let streamed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "line 3", "line 3"),
            object: output
        )
        XCTAssertEqual(XCTWaiter.wait(for: [streamed], timeout: 6), .completed)

        // The chip's "Completed" state lasts only 4 s; the output panel's
        // "Exit 0" status persists, so it is the reliable completion signal.
        let status = app.descendants(matching: .any)["script.output.status"].firstMatch
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Exit 0", "Exit 0"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 8), .completed)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Script command streamed output"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testScriptArgumentFilledViaTab() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("greet")

        XCTAssertTrue(app.buttons["result.Greet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["argument.0"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["header.tabHint"].exists || app.staticTexts["Tab"].exists)

        // app-level typing goes to whatever holds focus; element-level typing
        // would re-focus the search field and undo the Tab.
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("world")
        app.typeKey(.return, modifierFlags: [])

        // fullOutput mode opens the output panel automatically.
        let output = app.descendants(matching: .any)["script.output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        let streamed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "hello-world", "hello-world"),
            object: output
        )
        XCTAssertEqual(XCTWaiter.wait(for: [streamed], timeout: 6), .completed)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Script argument via Tab"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSystemSettingsAreSearchable() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("sound")

        let settingsResult = app.buttons["result.Sound"]
        XCTAssertTrue(settingsResult.waitForExistence(timeout: 3))
        XCTAssertTrue(settingsResult.label.contains("System Settings"))
    }

    func testHotKeyCanBeChangedFromSettings() {
        app.buttons["header.settings"].click()
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 2))

        let recorder = app.buttons["settings.hotkey.recorder"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 2))
        recorder.click()
        app.typeKey("l", modifierFlags: [.control, .shift])

        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "⌃⇧L"),
            object: recorder
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Configurable hotkey settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStartAtLoginCanBeToggledFromSettings() {
        app.buttons["header.settings"].click()
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 2))

        let toggle = app.checkBoxes["settings.startAtLogin"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        XCTAssertEqual(toggle.value as? Int, 0)

        toggle.click()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 1"),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Start at login toggle"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDarkAppearanceSupportsSearch() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("activity")

        XCTAssertTrue(app.buttons["result.Activity Monitor"].waitForExistence(timeout: 3))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Dark appearance"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
