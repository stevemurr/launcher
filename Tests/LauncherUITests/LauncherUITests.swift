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
