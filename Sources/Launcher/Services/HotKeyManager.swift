import AppKit
import Carbon
import Foundation

private let launcherHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        manager.handleHotKeyPressed()
        return noErr
    case UInt32(kEventHotKeyReleased):
        manager.handleHotKeyReleased()
        return noErr
    default:
        return OSStatus(eventNotHandledErr)
    }
}

struct HotKeyPressGate {
    private(set) var isPressed = false

    mutating func press() -> Bool {
        guard !isPressed else { return false }
        isPressed = true
        return true
    }

    mutating func release() {
        isPressed = false
    }
}

final class HotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyReference: EventHotKeyRef?
    private var localEventMonitor: Any?
    private var registeredHotKey: HotKey?
    private var pressGate = HotKeyPressGate()
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        _ = eventTypes.withUnsafeBufferPointer { types in
            InstallEventHandler(
                GetApplicationEventTarget(),
                launcherHotKeyHandler,
                types.count,
                types.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }

        // RegisterEventHotKey can leave the foreground app's focused control
        // handling the shortcut as an ordinary key event. Catch that local
        // event so the same shortcut dismisses Launcher while it is visible.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            guard let self,
                  let registeredHotKey = self.registeredHotKey,
                  registeredHotKey.matches(event) else {
                return event
            }

            switch event.type {
            case .keyDown:
                if !event.isARepeat {
                    self.handleHotKeyPressed()
                }
            case .keyUp:
                self.handleHotKeyReleased()
            default:
                break
            }
            return nil
        }
    }

    deinit {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    @discardableResult
    func register(_ hotKey: HotKey) -> OSStatus {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        registeredHotKey = nil
        pressGate.release()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4C_4E_43_48, id: 1) // LNCH
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKeyReference = reference
            registeredHotKey = hotKey
        }
        return status
    }

    fileprivate func handleHotKeyPressed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pressGate.press() else { return }
            self.onPress()
        }
    }

    fileprivate func handleHotKeyReleased() {
        DispatchQueue.main.async { [weak self] in
            self?.pressGate.release()
        }
    }
}
