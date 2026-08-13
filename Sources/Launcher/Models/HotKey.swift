import AppKit
import Carbon
import Foundation

struct HotKeyModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt

    static let control = HotKeyModifiers(rawValue: 1 << 0)
    static let option = HotKeyModifiers(rawValue: 1 << 1)
    static let shift = HotKeyModifiers(rawValue: 1 << 2)
    static let command = HotKeyModifiers(rawValue: 1 << 3)

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value: HotKeyModifiers = []
        if eventFlags.contains(.control) { value.insert(.control) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        if eventFlags.contains(.command) { value.insert(.command) }
        self = value
    }

    var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        if contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    var displayString: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

struct HotKey: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: HotKeyModifiers

    static let `default` = HotKey(keyCode: UInt32(kVK_Space), modifiers: [.option])

    var displayString: String {
        modifiers.displayString + Self.keyName(for: keyCode)
    }

    var carbonModifiers: UInt32 {
        modifiers.carbonValue
    }

    /// Shift-only global shortcuts collide with ordinary uppercase typing.
    /// Require at least one modifier that is conventionally used to reserve a
    /// command chord; Shift may still be combined with any of them.
    var isSafeGlobalShortcut: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode
            && HotKeyModifiers(eventFlags: event.modifierFlags) == modifiers
    }

    private static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_Escape): "⎋", UInt32(kVK_Home): "↖",
            UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞",
            UInt32(kVK_PageDown): "⇟", UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_ANSI_Minus): "–",
            UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_LeftBracket): "[",
            UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Grave): "`",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2",
            UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
            UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}
