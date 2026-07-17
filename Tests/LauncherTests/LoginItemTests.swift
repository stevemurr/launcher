import XCTest
@testable import Launcher

private final class StubLoginItemService: LoginItemService {
    var isEnabled = false
    var nextError: Error?
    private(set) var setCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if let nextError { throw nextError }
        isEnabled = enabled
    }
}

final class LoginItemTests: XCTestCase {
    private func makeModel(service: StubLoginItemService) -> LauncherModel {
        LauncherModel(
            settings: LauncherSettings(defaults: UserDefaults(suiteName: "LoginItemTests")!),
            isUITesting: true,
            loginItems: service
        )
    }

    func testInitialStateReflectsService() {
        let service = StubLoginItemService()
        service.isEnabled = true
        XCTAssertTrue(makeModel(service: service).launchAtLogin)
    }

    func testEnablingRegistersLoginItem() {
        let service = StubLoginItemService()
        let model = makeModel(service: service)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(service.setCalls, [true])
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertNil(model.launchAtLoginError)
    }

    func testDisablingUnregistersLoginItem() {
        let service = StubLoginItemService()
        service.isEnabled = true
        let model = makeModel(service: service)

        model.setLaunchAtLogin(false)

        XCTAssertEqual(service.setCalls, [false])
        XCTAssertFalse(model.launchAtLogin)
    }

    func testRedundantUpdateDoesNotTouchService() {
        let service = StubLoginItemService()
        let model = makeModel(service: service)

        model.setLaunchAtLogin(false)

        XCTAssertTrue(service.setCalls.isEmpty)
    }

    func testFailureSurfacesErrorAndKeepsStateInSync() {
        let service = StubLoginItemService()
        service.nextError = NSError(domain: "LoginItemTests", code: 1)
        let model = makeModel(service: service)

        model.setLaunchAtLogin(true)

        XCTAssertFalse(model.launchAtLogin)
        XCTAssertNotNil(model.launchAtLoginError)

        service.nextError = nil
        model.setLaunchAtLogin(true)

        XCTAssertTrue(model.launchAtLogin)
        XCTAssertNil(model.launchAtLoginError)
    }
}
