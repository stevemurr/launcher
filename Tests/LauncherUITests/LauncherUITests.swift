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
        if name.contains("testNativeTerminalRestoresColorEnvironment") {
            // Reproduce launching Launcher from a host (including Codex) that
            // exports the presentation-only NO_COLOR policy.
            app.launchEnvironment["NO_COLOR"] = "1"
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

    func testShellModeUsesAFullNativeTerminalForConsecutiveCommands() {
        let terminal = enterNativeTerminal()
        let console = app.descendants(matching: .any)["shell.console"].firstMatch

        XCTAssertTrue(waitForPanelWidth(990), "terminal mode did not expand to the drawer width")
        XCTAssertFalse(app.textFields["launcher.search"].exists, "launcher search must leave the hierarchy")
        XCTAssertFalse(app.descendants(matching: .any)["shell.output"].firstMatch.exists)
        XCTAssertFalse(app.buttons["shell.run"].exists)
        XCTAssertFalse(app.buttons["footer.actions"].exists)
        XCTAssertTrue(app.buttons["shell.returnToLauncher"].exists)

        let dialog = app.dialogs.firstMatch
        let panelFrame = (dialog.exists ? dialog : app.windows.firstMatch).frame
        XCTAssertEqual(console.frame.minX, panelFrame.minX, accuracy: 2)
        XCTAssertEqual(console.frame.maxX, panelFrame.maxX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(
            terminal.frame.minX - panelFrame.minX,
            2,
            "the native terminal should sit inside the thin left bezel"
        )
        XCTAssertGreaterThanOrEqual(
            panelFrame.maxX - terminal.frame.maxX,
            2,
            "the native terminal should sit inside the thin right bezel"
        )

        let workingDirectory = app.descendants(matching: .any)["shell.workingDirectory"].firstMatch
        sendTerminalCommand("cd /tmp", to: terminal)
        XCTAssertTrue(
            waitForElement(workingDirectory, containing: "tmp"),
            "native shell did not change to /tmp"
        )

        sendTerminalCommand("cd /var", to: terminal)
        XCTAssertTrue(
            waitForElement(workingDirectory, containing: "var"),
            "a consecutive command did not reach the retained native shell"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Full-width native terminal"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeTerminalSessionsListNewestFirstAndResumeTheirExactState() {
        let firstTerminal = enterNativeTerminal()
        let workingDirectory = app.descendants(matching: .any)["shell.workingDirectory"].firstMatch

        sendTerminalCommand("cd /tmp", to: firstTerminal)
        XCTAssertTrue(
            waitForElement(workingDirectory, containing: "tmp"),
            "Shell 1 did not adopt its expected /tmp working directory"
        )

        returnToLauncherFromTerminal()
        XCTAssertTrue(app.staticTexts["Running Shells"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["result.Shell 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForRunningShellRows(["result.Shell 1"]),
            "the first native terminal was not listed as Shell 1"
        )

        // A bare > always creates a fresh terminal. Existing terminals resume
        // through their pinned result rows instead.
        let secondTerminal = enterNativeTerminal()
        let secondWorkingDirectory = app.descendants(matching: .any)["shell.workingDirectory"].firstMatch
        sendTerminalCommand("cd /var", to: secondTerminal)
        XCTAssertTrue(
            waitForElement(secondWorkingDirectory, containing: "var"),
            "Shell 2 did not adopt its expected /var working directory"
        )

        returnToLauncherFromTerminal()
        XCTAssertTrue(
            waitForRunningShellRows(["result.Shell 2", "result.Shell 1"]),
            "native terminals must be pinned newest-first as Shell 2, then Shell 1"
        )

        // Resume the older terminal first and prove that its PTY state did not
        // bleed together with the newer terminal's state. Use the keyboard so
        // this also pins the visual-selection regression for retained shells.
        let search = app.textFields["launcher.search"]
        let newestShell = app.buttons["result.Shell 2"]
        let olderShell = app.buttons["result.Shell 1"]
        XCTAssertTrue(waitForSelection(newestShell), "the leading shell row was not visibly selected")
        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelection(olderShell), "keyboard selection did not repaint Shell 1")
        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForSelection(app.buttons["result.Launcher Settings"]),
            "selection did not repaint across the Running Shells/Results boundary"
        )
        search.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelection(olderShell), "keyboard selection did not repaint back to Shell 1")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForNativeTerminal().exists)
        let resumedFirstDirectory = app.descendants(matching: .any)["shell.workingDirectory"].firstMatch
        XCTAssertTrue(
            waitForElement(resumedFirstDirectory, containing: "tmp"),
            "resuming Shell 1 did not restore its /tmp working directory"
        )

        returnToLauncherFromTerminal()
        XCTAssertTrue(
            waitForRunningShellRows(["result.Shell 2", "result.Shell 1"]),
            "resuming Shell 1 must not reorder or replace either session"
        )

        let resumedSearch = app.textFields["launcher.search"]
        XCTAssertTrue(waitForSelection(app.buttons["result.Shell 2"]))
        resumedSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForNativeTerminal().exists)
        let resumedSecondDirectory = app.descendants(matching: .any)["shell.workingDirectory"].firstMatch
        XCTAssertTrue(
            waitForElement(resumedSecondDirectory, containing: "var"),
            "resuming Shell 2 did not restore its /var working directory"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Resumed native Shell 2"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShellEscapeStaysInTerminalAndCommandKReturnsToLauncher() {
        let terminal = enterNativeTerminal()
        let console = app.descendants(matching: .any)["shell.console"].firstMatch

        terminal.click()
        app.typeText("unfinished terminal input")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(console.exists, "Escape must remain a normal terminal key")
        XCTAssertTrue(terminal.exists)
        XCTAssertFalse(app.textFields["launcher.search"].exists)
        XCTAssertTrue(waitForPanelWidth(990), "Escape unexpectedly collapsed terminal mode")

        app.buttons["header.settings"].click()
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            console.waitForExistence(timeout: 5),
            "Escape in Settings should return to the retained terminal"
        )

        app.typeKey("k", modifierFlags: [.command])

        let search = app.textFields["launcher.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Command-K did not return to the launcher")
        XCTAssertTrue(waitForPanelWidth(774), "Command-K did not restore the compact launcher width")
        XCTAssertFalse(console.exists)
        XCTAssertEqual(search.value as? String, "")
    }

    func testShellTerminalOwnsForegroundStandardInputAndInterrupts() {
        let terminal = enterNativeTerminal()
        let workingDirectory = app.descendants(matching: .any)["shell.workingDirectory"].firstMatch

        sendTerminalCommand("/bin/cat", to: terminal)
        Thread.sleep(forTimeInterval: 0.4)
        app.typeText("native-terminal-input")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("c", modifierFlags: [.control])
        Thread.sleep(forTimeInterval: 0.4)

        sendTerminalCommand("cd /tmp", to: terminal)
        XCTAssertTrue(
            waitForElement(workingDirectory, containing: "tmp"),
            "Control-C should interrupt the foreground program without killing the terminal shell"
        )
        XCTAssertFalse(app.textFields["launcher.search"].exists)
        XCTAssertFalse(app.secureTextFields["launcher.search"].exists)
    }

    func testNativeTerminalRestoresColorEnvironment() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-terminal-color-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        let terminal = enterNativeTerminal()
        sendTerminalCommand(
            "/usr/bin/printf '%s|%s|%s' \"$TERM\" \"$COLORTERM\" \"${NO_COLOR-unset}\" > '\(marker.path)'",
            to: terminal
        )

        XCTAssertEqual(
            waitForFileContents(at: marker),
            "xterm-256color|truecolor|unset",
            "Ghostty should supply terminal capabilities without inheriting the host's NO_COLOR policy"
        )
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

    private func enterNativeTerminal(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let search = app.textFields["launcher.search"]
        search.click()
        search.typeText(">")

        let terminal = waitForNativeTerminal(file: file, line: line)
        XCTAssertFalse(
            search.exists,
            "terminal mode must remove the launcher input field",
            file: file,
            line: line
        )
        return terminal
    }

    private func waitForNativeTerminal(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let console = app.descendants(matching: .any)["shell.console"].firstMatch
        let terminal = app.descendants(matching: .any)["launcher.terminal.surface"].firstMatch
        XCTAssertTrue(
            console.waitForExistence(timeout: 5),
            "the > trigger did not enter terminal mode",
            file: file,
            line: line
        )
        XCTAssertTrue(
            terminal.waitForExistence(timeout: 8),
            "the native Ghostty surface did not appear",
            file: file,
            line: line
        )

        let status = app.descendants(matching: .any)["shell.status"].firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", "Ready", "Ready"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 8),
            .completed,
            "the native terminal surface did not become ready",
            file: file,
            line: line
        )
        return terminal
    }

    @discardableResult
    private func returnToLauncherFromTerminal(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        app.typeKey("k", modifierFlags: [.command])
        let search = app.textFields["launcher.search"]
        XCTAssertTrue(
            search.waitForExistence(timeout: 5),
            "Command-K did not return to launcher search",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForPanelWidth(774),
            "Command-K did not restore the compact launcher width",
            file: file,
            line: line
        )
        return search
    }

    private func sendTerminalCommand(_ command: String, to terminal: XCUIElement) {
        terminal.click()
        app.typeText(command)
        app.typeKey(.return, modifierFlags: [])
    }

    private func waitForElement(
        _ element: XCUIElement,
        containing expectedValue: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                expectedValue,
                expectedValue
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForRunningShellRows(
        _ expectedIdentifiers: [String],
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "result.Shell ")
        while Date() < deadline {
            let identifiers = app.buttons
                .matching(predicate)
                .allElementsBoundByIndex
                .map(\.identifier)
            if identifiers == expectedIdentifiers { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForSelection(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.value as? String == "Selected" { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForFileContents(
        at url: URL,
        timeout: TimeInterval = 5
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
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
