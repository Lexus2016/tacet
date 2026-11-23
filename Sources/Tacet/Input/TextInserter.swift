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

    /// Pastes with ⌘V. Returns false when Accessibility is not granted, in which
    /// case the caller leaves the text on the clipboard.
    @discardableResult
    static func paste() -> Bool {
        guard isAccessibilityTrusted() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        usleep(45_000)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        return true
    }

    /// Sends Backspace, which removes the current selection.
    @discardableResult
    static func deleteSelection() -> Bool {
        guard isAccessibilityTrusted(), let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        usleep(45_000)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    static var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
