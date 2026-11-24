import AppKit

@MainActor
struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]
    let changeCount: Int

    init?(_ pasteboard: NSPasteboard) {
        let changeCount = pasteboard.changeCount
        let originals = pasteboard.pasteboardItems ?? []
        var copies: [NSPasteboardItem] = []
        for original in originals {
            let copy = NSPasteboardItem()
            let types = original.types
            for type in types {
                // Copying a promise would detach it from the app that fulfills it.
                // Копіювання обіцянки створити файл від’єднає її від початкового застосунку.
                if type.rawValue.hasPrefix("com.apple.pasteboard.promised-file") { return nil }
                let data = original.data(forType: type)
                // AppKit can advertise a synthesized UTF-16 flavor with no bytes.
                // AppKit може оголосити похідний формат UTF-16 без даних.
                if type.rawValue == "public.utf16-external-plain-text",
                   types.contains(.string), data == nil { continue }
                guard let data, copy.setData(data, forType: type) else {
                    return nil
                }
            }
            copies.append(copy)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        self.changeCount = changeCount
        items = copies
    }

    @discardableResult
    func restore(_ pasteboard: NSPasteboard, ifUnchangedSince ownedChange: Int) -> Bool {
        guard pasteboard.changeCount == ownedChange else { return false }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }
}

private final class TemporaryPasteText: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let lock = NSLock()
    private var supplied = false

    init(_ text: String) {
        self.text = text
    }

    var wasRequested: Bool { lock.withLock { supplied } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let written = item.setString(text, forType: type)
        if written { lock.withLock { supplied = true } }
    }
}

@MainActor
enum TemporaryClipboard {
    enum SelectionCopy: Equatable {
        case unchanged
        case text(String)
        case unavailable
    }

    static func paste(_ text: String, on pasteboard: NSPasteboard, send: () -> Bool) async -> Bool {
        guard !Task.isCancelled, let snapshot = ClipboardSnapshot(pasteboard) else { return false }

        let provider = TemporaryPasteText(text)
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else { return false }
        // Clipboard managers can skip temporary dictation text.
        // Менеджери буфера можуть пропустити тимчасовий текст диктування.
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))

        guard pasteboard.changeCount == snapshot.changeCount else { return false }
        let cleared = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            snapshot.restore(pasteboard, ifUnchangedSince: cleared)
            return false
        }
        defer { snapshot.restore(pasteboard, ifUnchangedSince: cleared) }
        guard pasteboard.changeCount == cleared, send() else { return false }

        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(900)
        while clock.now < deadline, pasteboard.changeCount == cleared {
            if provider.wasRequested {
                // A reader may fetch the same flavor again as it handles the paste.
                // Під час вставлення редактор може перечитати той самий формат.
                try? await Task.sleep(for: .milliseconds(60))
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(15))
            } catch {
                return provider.wasRequested
            }
        }
        return provider.wasRequested
    }

    static func readSelection(on pasteboard: NSPasteboard, send: () -> Bool) async -> SelectionCopy {
        guard !Task.isCancelled, let snapshot = ClipboardSnapshot(pasteboard),
              pasteboard.changeCount == snapshot.changeCount, send() else { return .unavailable }

        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(550)
        while clock.now < deadline {
            let copiedChange = pasteboard.changeCount
            if copiedChange != snapshot.changeCount {
                // More than one write can mean another app replaced the copy.
                // Кілька записів можуть означати, що інший застосунок змінив буфер.
                guard copiedChange == snapshot.changeCount + 1 else { return .unavailable }
                if pasteboard.pasteboardItems?.isEmpty == false {
                    let text = pasteboard.string(forType: .string)
                    guard snapshot.restore(pasteboard, ifUnchangedSince: copiedChange),
                          let text, !text.isEmpty else { return .unavailable }
                    return .text(text)
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(15))
            } catch {
                return .unavailable
            }
        }
        return pasteboard.changeCount == snapshot.changeCount ? .unchanged : .unavailable
    }
}
