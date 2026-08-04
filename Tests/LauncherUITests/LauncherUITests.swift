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

        search.typeKey("p", modifierFlags: [.command])
        let output = app.descendants(matching: .any)["script.output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 3))

        let streamed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "line 3", "line 3"),
            object: output
        )
        XCTAssertEqual(XCTWaiter.wait(for: [streamed], timeout: 6), .completed)

        let status = app.descendants(matching: .any)["script.output.status"].firstMatch
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Exit 0", "Exit 0"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 8), .completed)

        // The chip no longer auto-hides: it keeps reporting the exit status for
        // as long as the run is on screen.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(chip.exists)
        XCTAssertTrue(chip.label.contains("Completed"), "got \(chip.label)")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Script command streamed output"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testScriptOutputPaneOpensWithCommandP() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("say hello")

        XCTAssertTrue(app.buttons["result.Say Hello"].waitForExistence(timeout: 3))
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["footer.output"].waitForExistence(timeout: 3))

        search.typeKey("p", modifierFlags: [.command])
        let output = app.descendants(matching: .any)["script.output"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        let contents = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Hello from fixture",
                "Hello from fixture"
            ),
            object: output
        )
        XCTAssertEqual(XCTWaiter.wait(for: [contents], timeout: 5), .completed)
    }

    func testCommandPTogglesOutputPaneAndWindowWidth() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("say hello")

        XCTAssertTrue(app.buttons["result.Say Hello"].waitForExistence(timeout: 3))
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["footer.runChip"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForPanelWidth(774), "launcher did not start at the compact width")

        search.typeKey("p", modifierFlags: [.command])
        let pane = app.descendants(matching: .any)["script.outputPane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 3), "⌘P did not open the output pane")
        XCTAssertTrue(waitForPanelWidth(990), "the window did not widen for the pane")
        XCTAssertTrue(search.exists, "the search field must survive the drawer opening")

        search.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(waitForPanelWidth(774), "the window did not collapse back")
        XCTAssertTrue(search.exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Output pane collapsed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEscapeClosesOutputPaneBeforeHidingLauncher() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("say hello")

        XCTAssertTrue(app.buttons["result.Say Hello"].waitForExistence(timeout: 3))
        search.typeKey(.return, modifierFlags: [])
        search.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(waitForPanelWidth(990))

        search.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitForPanelWidth(774), "the first Escape should only close the pane")
        XCTAssertTrue(search.exists, "the first Escape must not hide the launcher")
    }

    /// Typing closes the pane from inside controlTextDidChange, which resizes
    /// the NSPanel while the field editor is live. The keystroke must land and
    /// the window must collapse.
    func testTypingWithOutputPaneOpenCollapsesWindow() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("say hello")

        XCTAssertTrue(app.buttons["result.Say Hello"].waitForExistence(timeout: 3))
        search.typeKey(.return, modifierFlags: [])

        let status = app.descendants(matching: .any)["script.output.status"].firstMatch
        search.typeKey("p", modifierFlags: [.command])
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Exit 0", "Exit 0"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
        XCTAssertTrue(waitForPanelWidth(990))

        // A completed run leaves the query selected (startRun refocuses search),
        // so this starts a fresh search rather than appending.
        app.typeText("activity")

        XCTAssertTrue(waitForPanelWidth(774), "typing should collapse the pane with the finished run")
        XCTAssertTrue(
            app.buttons["result.Activity Monitor"].waitForExistence(timeout: 3),
            "the keystrokes must survive the resize; query is \(String(describing: search.value))"
        )
        XCTAssertFalse(app.buttons["footer.runChip"].exists, "the finished run should be cleared")
    }

    /// ⌘P must not re-select the search field's contents — doing so would make
    /// the next keystroke replace the query instead of extending it.
    func testCommandPDoesNotDisturbTheQuery() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("activ")

        search.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(
            app.descendants(matching: .any)["script.outputPane"].firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(waitForPanelWidth(990))

        app.typeText("ity")

        XCTAssertTrue(
            app.buttons["result.Activity Monitor"].waitForExistence(timeout: 3),
            "⌘P clobbered the query; got \(String(describing: search.value))"
        )
    }

    /// A borderless NSPanel surfaces as a dialog to XCUITest on some builds and
    /// as a window on others, so check both.
    private func waitForPanelWidth(
        _ expectedWidth: CGFloat,
        accuracy: CGFloat = 3,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let dialog = app.dialogs.firstMatch
            let panel = dialog.exists ? dialog : app.windows.firstMatch
            if panel.exists, abs(panel.frame.width - expectedWidth) <= accuracy {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
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

        // No mode auto-opens the pane any more.
        app.typeKey("p", modifierFlags: [.command])
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

    // Palette and editor are reached via ⌘K/⌘E, not mouse clicks: mouse
    // travel to the footer or palette sweeps result rows and the hover
    // selection races the click (see testScriptCommandRunsWithStreamedOutput).
    func testEditScriptCommandFromActions() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("say hello")

        XCTAssertTrue(app.buttons["result.Say Hello"].waitForExistence(timeout: 3))

        search.typeKey("k", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["action.editScript"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["action.deleteScript"].exists)
        search.typeKey(.escape, modifierFlags: [])

        search.typeKey("e", modifierFlags: [.command])

        let titleField = app.textFields["createScript.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        XCTAssertEqual(titleField.value as? String, "Say Hello")

        titleField.click()
        titleField.typeKey("a", modifierFlags: [.command])
        titleField.typeText("Say Howdy")
        app.buttons["createScript.create"].click()

        XCTAssertTrue(app.buttons["result.Say Howdy"].waitForExistence(timeout: 3))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Edited script command"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Keyboard-driven (⌃X, then Return to confirm): with several results on
    // screen, mouse travel to the palette sweeps rows and the hover selection
    // races the click — same reason the run test avoids the mouse.
    func testDeleteScriptCommandFromActions() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("count")

        let result = app.buttons["result.Count Lines"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))

        search.typeKey("x", modifierFlags: [.control])

        let confirm = app.buttons["confirmDelete.delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Delete script confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)

        search.typeKey(.return, modifierFlags: [])

        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
    }

    // Keyboard-driven like the script tests: mouse travel over rows changes
    // the hover selection and races clicks. Quick Look (⌘Y) is not driven
    // here — the QL panel is flaky under XCUITest in a VM; its wiring is
    // covered by unit tests (testQuickLookActionFiresCallback).
    func testFileBrowserNavigatesWithEnterAndEscape() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("~/")

        // Fixture home: Alpha/ (with Inner.txt), Notes.txt, Read Me.md, .hidden.txt.
        XCTAssertTrue(app.buttons["result.Alpha"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["result.Notes.txt"].exists)
        XCTAssertFalse(app.buttons["result..hidden.txt"].exists)

        // The last path component filters the listing.
        search.typeText("Alph")
        XCTAssertTrue(app.buttons["result.Alpha"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["result.Notes.txt"].exists)

        // Enter descends: field clears, back button appears, contents swap.
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["header.back"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["result.Inner.txt"].waitForExistence(timeout: 3))

        // ⌘K shows the file actions.
        search.typeKey("k", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["action.openWith"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["action.quickLook"].exists)
        XCTAssertTrue(app.buttons["action.showInFinder"].exists)
        XCTAssertTrue(app.buttons["action.copyPath"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "File browser actions"
        attachment.lifetime = .keepAlways
        add(attachment)

        search.typeKey(.escape, modifierFlags: [])

        // Escape walks back up to the home listing, then exits the browser.
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["result.Notes.txt"].waitForExistence(timeout: 3))

        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["result.Launcher Settings"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["header.back"].exists)
    }

    // Arrow keys must drive selection while the search field is being edited
    // (the field editor would otherwise swallow them as caret movement) and,
    // when the ⌘K palette is open, must move the palette highlight instead.
    // The footer's primary-action label tracks the list selection, so it is
    // the observable signal for which row is selected.
    func testArrowKeysDriveSelectionAndActionsPalette() {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText("~/")

        // Fixture home lists Alpha/ (directory) first, then Notes.txt.
        XCTAssertTrue(app.buttons["result.Alpha"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Open Directory"].exists)

        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Open File"].waitForExistence(timeout: 2))

        search.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Open Directory"].waitForExistence(timeout: 2))

        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey("k", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["action.open"].waitForExistence(timeout: 2))

        // ↓ highlights "Open With…"; Return performs it.
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["openWith.title"].waitForExistence(timeout: 3))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Open With via arrow keys"
        attachment.lifetime = .keepAlways
        add(attachment)

        search.typeKey(.escape, modifierFlags: [])
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

    func testSettingsChromeAndReindexStayVisible() {
        app.buttons["header.settings"].click()

        let back = app.buttons["settings.back"]
        let reindex = app.buttons["settings.reindex"]
        let done = app.buttons["settings.done"]
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        XCTAssertTrue(reindex.waitForExistence(timeout: 2))
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(reindex.isHittable)
        XCTAssertTrue(done.isHittable)

        reindex.click()
        XCTAssertTrue(reindex.waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Settings layout with reindex"
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
