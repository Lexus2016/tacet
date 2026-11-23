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
