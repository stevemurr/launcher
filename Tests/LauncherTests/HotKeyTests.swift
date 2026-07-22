import Carbon
import XCTest
@testable import Launcher

final class HotKeyTests: XCTestCase {
    func testDefaultShortcutDisplay() {
        XCTAssertEqual(HotKey.default.displayString, "⌥Space")
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
}
