import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records a key combination by catching the next key press in the window.
/// Only combinations with at least one modifier are accepted, so the hotkey can
/// never swallow ordinary typing.
struct HotkeyRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var label: String
    var onChange: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                        .foregroundStyle(isRecording ? Theme.danger : .secondary)
                    Text(isRecording ? "Press keys…" : HotkeyFormat.title(modifiers: modifiers, label: label))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 110)
                }
            }
            .buttonStyle(SoftButtonStyle())

            if isRecording {
                Text("Esc to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard !isRecording else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape
                stop()
                return nil
            }

            let carbon = HotkeyFormat.carbon(event.modifierFlags)
            guard carbon != 0 else { return nil }

            keyCode = Int(event.keyCode)
            modifiers = carbon
            label = HotkeyFormat.label(for: event)
            stop()
            onChange()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

enum HotkeyFormat {
    static func carbon(_ flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.command) { value |= Int(cmdKey) }
        if flags.contains(.option) { value |= Int(optionKey) }
        if flags.contains(.control) { value |= Int(controlKey) }
        if flags.contains(.shift) { value |= Int(shiftKey) }
        return value
    }

    static func title(modifiers: Int, label: String) -> String {
        symbols(modifiers) + (label.isEmpty ? "Key" : label)
    }

    static func symbols(_ modifiers: Int) -> String {
        var text = ""
        if modifiers & Int(controlKey) != 0 { text += "⌃" }
        if modifiers & Int(optionKey) != 0 { text += "⌥" }
        if modifiers & Int(shiftKey) != 0 { text += "⇧" }
        if modifiers & Int(cmdKey) != 0 { text += "⌘" }
        return text
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return "F\(Int(event.keyCode) - kVK_F1 + 1)"
        default:
            let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let printable = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            return printable.isEmpty ? "Key \(event.keyCode)" : printable
        }
    }
}
