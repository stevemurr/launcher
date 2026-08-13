import AppKit
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    let hotKey: HotKey
    let onChange: (HotKey) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.hotKey = hotKey
        button.onChange = onChange
        button.updateTitle()
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.hotKey = hotKey
        button.onChange = onChange
        button.updateTitle()
    }
}

final class HotKeyRecorderButton: NSButton {
    var hotKey: HotKey = .default
    var onChange: ((HotKey) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .large
        font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        target = self
        action = #selector(beginRecording)
        identifier = NSUserInterfaceItemIdentifier("settings.hotkey.recorder")
        setAccessibilityIdentifier("settings.hotkey.recorder")
        toolTip = "Click, then press a shortcut"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            isRecording = false
            updateTitle()
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = HotKeyModifiers(eventFlags: event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let newHotKey = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard newHotKey.isSafeGlobalShortcut else {
            NSSound.beep()
            onChange?(newHotKey)
            return
        }
        hotKey = newHotKey
        isRecording = false
        updateTitle()
        onChange?(newHotKey)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if isRecording {
            isRecording = false
            updateTitle()
        }
        return result
    }

    func updateTitle() {
        guard !isRecording else { return }
        title = hotKey.displayString
        setAccessibilityLabel(hotKey.displayString)
    }
}
