import AppKit
import ApplicationServices
import Foundation

/// Reads the text selected in the frontmost app through the Accessibility API.
/// This is the same permission the app already needs to paste.
enum SelectionReader {
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef
        else { return nil }

        let element = focusedRef as! AXUIElement

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let text = selectedRef as? String
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// True when the focused element still has a selection. Used to make sure a
    /// replacement will actually replace something.
    static func hasSelection() -> Bool {
        selectedText() != nil
    }

    /// AX first; if the app does not expose the selection (Word, Sublime,
    /// many native editors), copy it with Command-C and restore the clipboard
    /// afterwards. This is the same fallback the competitors use.
    static func selectedTextOrCopy() -> String? {
        if let text = selectedText() { return text }
        guard AXIsProcessTrusted() else { return nil }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        usleep(140_000)
        let copied = pasteboard.string(forType: .string)

        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        guard let copied, copied != previous else { return nil }
        let trimmed = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : copied
    }

    /// A selection exists but the app refuses to hand over its text (common in
    /// web views). Pasting then would overwrite it with the spoken words.
    static func hasUnreadableSelection() -> Bool {
        guard AXIsProcessTrusted(), selectedText() == nil else { return false }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef
        else { return false }

        let element = focusedRef as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rangeRef
        else { return false }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return false }
        return range.length > 0
    }
}
