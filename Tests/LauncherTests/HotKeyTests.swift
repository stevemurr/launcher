import Carbon
import XCTest
@testable import Launcher

private final class HotKeyLoginItems: LoginItemService {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

final class HotKeyTests: XCTestCase {
    func testDefaultShortcutDisplay() {
        XCTAssertEqual(HotKey.default.displayString, "⌥Space")
        XCTAssertTrue(HotKey.default.isSafeGlobalShortcut)
    }

    func testShiftOnlyShortcutIsUnsafeForGlobalRegistration() {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.shift])

        XCTAssertFalse(hotKey.isSafeGlobalShortcut)
    }

    func testShiftRemainsValidWhenCombinedWithCommandModifier() {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.shift, .command])

        XCTAssertTrue(hotKey.isSafeGlobalShortcut)
    }

    func testModelRejectsShiftOnlyShortcutBeforeRegistration() {
        let defaults = UserDefaults(suiteName: "HotKeyTests-\(UUID().uuidString)")!
        let settings = LauncherSettings(defaults: defaults)
        let model = LauncherModel(
            settings: settings,
            loginItems: HotKeyLoginItems()
        )
        var attemptedRegistration = false
        model.onHotKeyChange = { _ in
            attemptedRegistration = true
            return true
        }

        model.updateHotKey(HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.shift]))

        XCTAssertFalse(attemptedRegistration)
        XCTAssertEqual(settings.hotKey, .default)
        XCTAssertNotNil(settings.hotKeyError)
    }

    func testPersistedShiftOnlyShortcutMigratesToSafeDefault() throws {
        let suite = "HotKeyMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let unsafe = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.shift])
        defaults.set(try JSONEncoder().encode(unsafe), forKey: "launcher.hotKey")

        let settings = LauncherSettings(defaults: defaults)

        XCTAssertEqual(settings.hotKey, .default)
        XCTAssertNotNil(settings.hotKeyError)
        let persisted = try JSONDecoder().decode(
            HotKey.self,
            from: XCTUnwrap(defaults.data(forKey: "launcher.hotKey"))
        )
        XCTAssertEqual(persisted, .default)
    }

    func testDisplayStringForMappedKeyShowsItsName() {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [])

        XCTAssertEqual(hotKey.displayString, "A")
    }

    func testDisplayStringForUnmappedKeyShowsNumericFallback() {
        // Keypad 1 (kVK_ANSI_Keypad1 == 0x53 == 83) is absent from the
        // `names` lookup table in HotKey.keyName(for:), so it exercises
        // the fallback branch.
        let hotKey = HotKey(keyCode: 83, modifiers: [])

        XCTAssertEqual(hotKey.displayString, "Key 83")
        XCTAssertFalse(hotKey.displayString.contains("(keyCode)"))
    }

    func testHotKeyMatchesForegroundKeyEvent() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .capsLock],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: UInt16(kVK_Space)
            )
        )

        XCTAssertTrue(HotKey.default.matches(event))
    }

    func testHotKeyRejectsDifferentForegroundModifiers() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: UInt16(kVK_Space)
            )
        )

        XCTAssertFalse(HotKey.default.matches(event))
    }

    func testPressGateRequiresReleaseBeforeAnotherToggle() {
        var gate = HotKeyPressGate()

        XCTAssertTrue(gate.press())
        XCTAssertFalse(gate.press())

        gate.release()

        XCTAssertTrue(gate.press())
    }
}
