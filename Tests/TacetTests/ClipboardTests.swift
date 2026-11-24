import AppKit
import XCTest
@testable import Tacet

@MainActor
final class ClipboardTests: XCTestCase {
    private func withPasteboard(_ test: (NSPasteboard) async -> Void) async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        await test(pasteboard)
    }

    func testPasteRestoresAllFormatsAndItems() async {
        await withPasteboard { pasteboard in
            let richText = NSPasteboardItem()
            richText.setString("Привіт", forType: .string)
            richText.setData(Data([1, 2, 3]), forType: .rtf)
            let image = NSPasteboardItem()
            image.setData(Data([4, 5, 6]), forType: .png)
            XCTAssertTrue(pasteboard.writeObjects([richText, image]))

            let posted = await TemporaryClipboard.paste("диктування", on: pasteboard) {
                XCTAssertEqual(pasteboard.string(forType: .string), "диктування")
                return true
            }

            XCTAssertTrue(posted)
            let restored = pasteboard.pasteboardItems
            XCTAssertEqual(restored?.count, 2)
            XCTAssertEqual(restored?.first?.string(forType: .string), "Привіт")
            XCTAssertEqual(restored?.first?.data(forType: .rtf), Data([1, 2, 3]))
            XCTAssertEqual(restored?.last?.data(forType: .png), Data([4, 5, 6]))
        }
    }

    func testPasteRollsBackARejectedEventAndRetainsARecentCopy() async {
        await withPasteboard { pasteboard in
            pasteboard.setString("before", forType: .string)
            let rejected = await TemporaryClipboard.paste("temporary", on: pasteboard) { false }
            XCTAssertFalse(rejected)
            XCTAssertEqual(pasteboard.string(forType: .string), "before")

            _ = await TemporaryClipboard.paste("temporary", on: pasteboard) {
                pasteboard.clearContents()
                pasteboard.setString("new user copy", forType: .string)
                return true
            }
            XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        }
    }

    func testPasteWaitsForSlowReaderBeforeRestoring() async {
        await withPasteboard { pasteboard in
            pasteboard.setString("original", forType: .string)
            let consumed = await TemporaryClipboard.paste("delayed paste", on: pasteboard) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(480))
                    XCTAssertEqual(pasteboard.string(forType: .string), "delayed paste")
                }
                return true
            }

            XCTAssertTrue(consumed)
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
        }
    }

    func testPasteReportsAnUnconsumedEventAndRestores() async {
        await withPasteboard { pasteboard in
            pasteboard.setString("original", forType: .string)

            let consumed = await TemporaryClipboard.paste("ignored paste", on: pasteboard) { true }

            XCTAssertFalse(consumed)
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
        }
    }

    func testCopyRecognizesTheSameTextAndRestoresItsFormatting() async {
        await withPasteboard { pasteboard in
            let richText = NSPasteboardItem()
            richText.setString("same", forType: .string)
            richText.setData(Data([5, 6]), forType: .rtf)
            XCTAssertTrue(pasteboard.writeObjects([richText]))

            let text = await TemporaryClipboard.readSelection(on: pasteboard) {
                pasteboard.clearContents()
                return pasteboard.setString("same", forType: .string)
            }

            XCTAssertEqual(text, .text("same"))
            XCTAssertEqual(pasteboard.data(forType: .rtf), Data([5, 6]))
        }
    }

    func testDelayedCopyRestoresAnInitiallyEmptyClipboard() async {
        await withPasteboard { pasteboard in
            let text = await TemporaryClipboard.readSelection(on: pasteboard) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(210))
                    pasteboard.clearContents()
                    pasteboard.setString("selection", forType: .string)
                }
                return true
            }

            XCTAssertEqual(text, .text("selection"))
            XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }

    func testCopyTimeoutDoesNotRewriteAnImageOnlyClipboard() async {
        await withPasteboard { pasteboard in
            pasteboard.setData(Data([8, 9, 10]), forType: .png)
            let before = pasteboard.changeCount

            let text = await TemporaryClipboard.readSelection(on: pasteboard) { true }

            XCTAssertEqual(text, .unchanged)
            XCTAssertEqual(pasteboard.changeCount, before)
            XCTAssertEqual(pasteboard.data(forType: .png), Data([8, 9, 10]))
        }
    }

    func testCopyPreservesASecondPasteboardWrite() async {
        await withPasteboard { pasteboard in
            pasteboard.setString("original", forType: .string)
            let text = await TemporaryClipboard.readSelection(on: pasteboard) {
                pasteboard.clearContents()
                pasteboard.setString("selection", forType: .string)
                pasteboard.clearContents()
                pasteboard.setString("new user copy", forType: .string)
                return true
            }

            XCTAssertEqual(text, .unavailable)
            XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        }
    }

    func testPasteLeavesFilePromiseAttachedToItsOwner() async {
        await withPasteboard { pasteboard in
            let promise = NSPasteboardItem()
            let type = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
            promise.setString("public.png", forType: type)
            XCTAssertTrue(pasteboard.writeObjects([promise]))

            let pasted = await TemporaryClipboard.paste("temporary", on: pasteboard) {
                XCTFail("A file promise must stay with its owner")
                return false
            }

            XCTAssertFalse(pasted)
            XCTAssertEqual(pasteboard.string(forType: type), "public.png")
        }
    }

    func testSublimeLineCopyCannotBeMistakenForASelection() {
        let app = "com.sublimetext.4"
        XCTAssertTrue(SelectionReader.mayBeSublimeLineCopy("whole line\n", appID: app, range: nil))
        XCTAssertFalse(SelectionReader.mayBeSublimeLineCopy("selected text", appID: app, range: nil))
        XCTAssertFalse(SelectionReader.mayBeSublimeLineCopy("two\nlines\n", appID: app, range: nil))
        XCTAssertFalse(SelectionReader.mayBeSublimeLineCopy("whole line\n", appID: app, range: CFRange(location: 0, length: 11)))
    }
}
