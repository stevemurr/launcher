import XCTest
@testable import Launcher

final class LauncherModelActivationTests: XCTestCase {
    func testLaunchingApplicationDismissesLauncherBeforeOpeningURL() {
        let defaults = UserDefaults(
            suiteName: "LauncherModelActivationTests-\(UUID().uuidString)"
        )!
        let model = LauncherModel(
            settings: LauncherSettings(defaults: defaults),
            isUITesting: true,
            loginItems: InMemoryLoginItemService()
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/Example.app")
        let item = LauncherItem(
            id: "com.example.Example",
            title: "Example",
            subtitle: nil,
            kind: .application,
            destination: .url(applicationURL),
            keywords: ""
        )
        var events: [String] = []

        model.onRequestClose = { events.append("dismiss") }
        model.urlOpener = { url in
            XCTAssertEqual(url, applicationURL)
            events.append("open")
        }

        model.activate(item)

        XCTAssertEqual(events, ["dismiss", "open"])
    }

    func testChildWindowTakingKeyDoesNotHideLauncher() {
        XCTAssertFalse(
            LauncherWindowLifecycle.shouldHideLauncher(
                appIsActive: true,
                launcherIsKey: false,
                hasAnotherKeyWindow: true,
                quickLookIsVisible: false
            )
        )
    }

    func testSwitchingToAnotherAppHidesLauncher() {
        XCTAssertTrue(
            LauncherWindowLifecycle.shouldHideLauncher(
                appIsActive: false,
                launcherIsKey: false,
                hasAnotherKeyWindow: false,
                quickLookIsVisible: false
            )
        )
    }

    func testQuickLookAndRekeyedLauncherStayVisible() {
        XCTAssertFalse(
            LauncherWindowLifecycle.shouldHideLauncher(
                appIsActive: true,
                launcherIsKey: false,
                hasAnotherKeyWindow: true,
                quickLookIsVisible: true
            )
        )
        XCTAssertFalse(
            LauncherWindowLifecycle.shouldHideLauncher(
                appIsActive: true,
                launcherIsKey: true,
                hasAnotherKeyWindow: false,
                quickLookIsVisible: false
            )
        )
    }
}
