import AppKit
import ApplicationServices

@MainActor
enum TextInserter {
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func paste(_ text: String, in focus: SelectionReader.Focus) async -> Bool {
        guard isAccessibilityTrusted(), focus.isCurrent else { return false }
        return await TemporaryClipboard.paste(text, on: .general) {
            focus.isCurrent && sendKey(0x09, command: true, to: focus.application)
        }
    }

    static func sendKey(_ key: CGKeyCode, command: Bool = false, to application: NSRunningApplication) -> Bool {
        guard isAccessibilityTrusted(), !application.isTerminated,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }

        down.flags = command ? .maskCommand : []
        up.flags = down.flags
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
        return true
    }
}
