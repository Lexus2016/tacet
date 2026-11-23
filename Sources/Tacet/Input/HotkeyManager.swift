import AppKit
import Carbon.HIToolbox
import Foundation

/// Carbon hotkeys work without Accessibility permission and deliver both press
/// and release, which is what push-to-talk needs.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Called when a modifier-only press turned out to be a normal shortcut
    /// (another key was pressed while the modifier was held).
    var onCancel: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    private var modifierMonitor: Any?
    private var modifierMask: NSEvent.ModifierFlags = []
    private var modifierKeyCode: Int = 0
    private var modifierDown = false
    private var modifierStarted = false
    private var modifierSawKey = false
    private var pendingPress: DispatchWorkItem?

    deinit {
        unregister()
    }

    // MARK: Modifier-only

    /// A lone modifier cannot be a Carbon hotkey: it produces flagsChanged, not
    /// a key press. The monitor waits a moment before starting, so Command-C
    /// does not flash a recording.
    @discardableResult
    func registerModifierOnly(_ mask: NSEvent.ModifierFlags, keyCode: Int = 0) -> Bool {
        unregister()
        modifierMask = mask
        modifierKeyCode = keyCode

        guard AXIsProcessTrusted() else {
            NSLog("Tacet: modifier-only hotkey needs Accessibility")
            return false
        }

        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleModifierEvent(event)
        }

        isRegistered = modifierMonitor != nil
        return isRegistered
    }

    private func handleModifierEvent(_ event: NSEvent) {
        let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])

        switch event.type {
        case .flagsChanged:
            let isDown = relevant == modifierMask
                && (modifierKeyCode == 0 || Int(event.keyCode) == modifierKeyCode)

            if isDown, !modifierDown {
                modifierDown = true
                modifierStarted = false
                modifierSawKey = false

                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.modifierDown, !self.modifierSawKey else { return }
                    self.modifierStarted = true
                    self.onPress?()
                }
                pendingPress = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)

            } else if !isDown, modifierDown {
                modifierDown = false
                pendingPress?.cancel()
                pendingPress = nil

                if modifierStarted {
                    modifierStarted = false
                    onRelease?()
                }
            }

        case .keyDown:
            guard modifierDown else { return }
            modifierSawKey = true
            pendingPress?.cancel()
            pendingPress = nil

            if modifierStarted {
                modifierStarted = false
                onCancel?()
            }

        default:
            break
        }
    }

    // MARK: Carbon

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
        pendingPress?.cancel()
        pendingPress = nil
        modifierDown = false
        modifierStarted = false

        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
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

/// Presets instead of a full shortcut recorder: a few well-known combinations
/// cover dictation, and a recorder is a feature the lite app does not need.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case optionSpace
    case commandShiftSpace
    case controlShiftSpace
    case commandOptionSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥ Space"
        case .optionSpace: return "⌥ Space"
        case .commandShiftSpace: return "⌘⇧ Space"
        case .controlShiftSpace: return "⌃⇧ Space"
        case .commandOptionSpace: return "⌘⌥ Space"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .optionSpace: return UInt32(optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .commandOptionSpace: return UInt32(cmdKey | optionKey)
        }
    }

    static func matching(keyCode: Int, modifiers: Int) -> HotkeyPreset? {
        allCases.first { Int($0.keyCode) == keyCode && Int($0.modifiers) == modifiers }
    }
}
