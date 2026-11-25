import AppKit
import ApplicationServices
import UniformTypeIdentifiers

@MainActor
enum SelectionReader {
    private static let sublimeID = "com.sublimetext.4"
    // AppKit maps the legacy pasteboard name to a public.data-conforming type.
    // AppKit зіставляє стару назву формату буфера з типом, що відповідає public.data.
    static let sublimeMetadata = UTType(tag: "sublime-text-extra", tagClass: .init(rawValue: "com.apple.nspboard-type"),
                                       conformingTo: .data).map { NSPasteboard.PasteboardType($0.identifier) }

    enum Selection: Equatable {
        case none
        case text(String, range: CFRange?)
        case unreadable

        static func == (lhs: Selection, rhs: Selection) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.unreadable, .unreadable):
                return true
            case let (.text(a, aRange), .text(b, bRange)):
                return a == b && aRange?.location == bRange?.location && aRange?.length == bRange?.length
            default:
                return false
            }
        }
    }

    @MainActor
    struct Focus {
        let application: NSRunningApplication
        let window: AXUIElement?
        let element: AXUIElement?

        init?(for target: NSRunningApplication? = nil) {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  target == nil || target?.processIdentifier == front.processIdentifier else { return nil }
            application = front
            if AXIsProcessTrusted() {
                let app = AXUIElementCreateApplication(front.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.25)
                window = SelectionReader.element(of: app, attribute: kAXFocusedWindowAttribute)
                element = SelectionReader.element(of: app, attribute: kAXFocusedUIElementAttribute)
            } else {
                window = nil
                element = nil
            }
        }

        var isCurrent: Bool {
            guard !application.isTerminated, let current = Focus(),
                  current.application.processIdentifier == application.processIdentifier else { return false }
            return window == current.window && element == current.element
        }
    }

    static func read(in focus: Focus) async -> Selection {
        guard AXIsProcessTrusted(), focus.isCurrent else { return .unreadable }
        let range = focus.element.flatMap(selectedRange)
        if range?.length == 0 { return .none }

        if let element = focus.element,
           let text = value(of: element, attribute: kAXSelectedTextAttribute) as? String {
            if !text.isEmpty { return .text(text, range: range) }
            if range == nil { return .none }
        }

        // Some editors provide a selection only through their Copy command.
        // Деякі редактори віддають виділення лише через команду копіювання.
        let appID = focus.application.bundleIdentifier
        let copied = await TemporaryClipboard.readSelection(on: .general, metadataType: appID == sublimeID ? sublimeMetadata : nil) {
            focus.isCurrent && TextInserter.sendKey(0x08, command: true, to: focus.application)
        }
        guard focus.isCurrent else { return .unreadable }
        switch copied {
        case .text(let text, let metadata):
            return copiedSelection(text, appID: appID, range: range, metadata: metadata)
        case .unchanged: return range == nil ? .none : .unreadable
        case .unavailable: return .unreadable
        }
    }

    static func copiedSelection(_ text: String, appID: String?, range: CFRange?, metadata: Data?) -> Selection {
        // Sublime's clipboard version 3 marks implicit line copies with byte 4.
        // У версії 3 формату буфера Sublime байт 4 позначає автоматичне копіювання рядка.
        if appID == sublimeID, range == nil, let metadata, metadata.count >= 9,
           metadata.prefix(4).elementsEqual([3, 0, 0, 0]), let flag = metadata.dropFirst(4).first {
            if flag == 1 { return .none }
            if flag == 0 { return .text(text, range: nil) }
        }
        if mayBeSublimeLineCopy(text, appID: appID, range: range) { return .unreadable }
        return .text(text, range: range)
    }

    static func mayBeSublimeLineCopy(_ text: String, appID: String?, range: CFRange?) -> Bool {
        // Sublime copies a whole line with a trailing newline even when nothing is selected.
        // Sublime копіює рядок із переносом навіть за відсутності виділення.
        guard appID == sublimeID, range == nil, text.last?.isNewline == true else { return false }
        return !text.dropLast().contains(where: \.isNewline)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = value(of: element, attribute: kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func element(of app: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = value(of: app, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func value(of element: AXUIElement, attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result
    }
}
