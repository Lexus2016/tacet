import Carbon.HIToolbox
import Foundation

/// Carbon hotkeys work without Accessibility permission and deliver both press
/// and release, which is what push-to-talk needs.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    deinit {
        unregister()
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        manager.onPress?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        manager.onRelease?()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            context,
            &handlerRef
        )

        guard status == noErr else {
            NSLog("Tacet: hotkey event handler failed (\(status))")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5441_4354), id: 1) // 'TACT'
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        isRegistered = registerStatus == noErr
        if !isRegistered {
            NSLog("Tacet: hotkey registration failed (\(registerStatus)); it is probably taken")
        }
        return isRegistered
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isRegistered = false
    }
}

/// Presets instead of a full shortcut recorder: three well-known combinations
/// cover dictation, and a recorder is a feature the lite app does not need.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case optionSpace
    case controlOptionSpace
    case commandShiftSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .commandShiftSpace: return "⌘⇧ Space"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }

    static func matching(keyCode: Int, modifiers: Int) -> HotkeyPreset? {
        allCases.first { Int($0.keyCode) == keyCode && Int($0.modifiers) == modifiers }
    }
}
