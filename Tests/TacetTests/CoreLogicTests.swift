import XCTest
import AppKit
@testable import Tacet

final class UpdateRestartGateTests: XCTestCase {
    func testWaitsForForegroundAndBackgroundDictation() {
        var gate = UpdateRestartGate()
        XCTAssertFalse(gate.reserve(isIdle: false))
        gate.activeTranscriptions = 2
        XCTAssertFalse(gate.reserve(isIdle: true))
        gate.activeTranscriptions -= 1
        XCTAssertFalse(gate.reserve(isIdle: true))
        gate.activeTranscriptions -= 1
        XCTAssertTrue(gate.reserve(isIdle: true))
    }

    func testReservesOnceAndReleasesAfterAnAbortedUpdate() {
        var gate = UpdateRestartGate()
        XCTAssertTrue(gate.reserve(isIdle: true))
        XCTAssertTrue(gate.isRestarting)
        XCTAssertFalse(gate.reserve(isIdle: true))
        gate.release()
        XCTAssertFalse(gate.isRestarting)
        XCTAssertTrue(gate.reserve(isIdle: true))
    }
}

final class LanguagePolicyTests: XCTestCase {
    private func transcript(_ text: String, language: String?, score: Double = 0.8) -> Transcript {
        Transcript(text: text, language: language, engine: "test", score: score, latency: 0)
    }

    func testUkrainianMarkers() {
        XCTAssertEqual(LanguagePolicy.cyrillicVerdict("Привіт, як справи?"), "uk")
        XCTAssertEqual(LanguagePolicy.cyrillicVerdict("Це її єдиний ґудзик"), "uk")
    }

    func testRussianMarkers() {
        XCTAssertEqual(LanguagePolicy.cyrillicVerdict("Это был съёмочный день"), "ru")
        XCTAssertEqual(LanguagePolicy.cyrillicVerdict("Съешь ещё этих мягких булок"), "ru")
    }

    func testAmbiguousCyrillicHasNoVerdict() {
        XCTAssertNil(LanguagePolicy.cyrillicVerdict("Так"))
        XCTAssertNil(LanguagePolicy.cyrillicVerdict("Добрий день"))
        // No Russian-only letters: the script check cannot decide, the
        // confidence of the second decode has to.
        XCTAssertNil(LanguagePolicy.cyrillicVerdict("Привет, как дела?"))
    }

    func testLanguageNameNormalisation() {
        XCTAssertEqual(LanguagePolicy.normalize("Ukrainian"), "uk")
        XCTAssertEqual(LanguagePolicy.normalize("uk-UA"), "uk")
        XCTAssertEqual(LanguagePolicy.normalize("RUSSIAN"), "ru")
        XCTAssertEqual(LanguagePolicy.normalize("en"), "en")
        XCTAssertNil(LanguagePolicy.normalize(nil))
    }

    func testAlternateIsChosenWhenScriptContradictsDetection() {
        let result = transcript("Привет, как дела?", language: "uk")
        XCTAssertEqual(LanguagePolicy.alternate(for: result), "ru")
    }

    func testAlternateIsChosenForAmbiguousCyrillic() {
        let result = transcript("Добрий день", language: "uk")
        XCTAssertEqual(LanguagePolicy.alternate(for: result), "ru")
    }

    func testNoSecondPassForLatinText() {
        let result = transcript("Good morning", language: "en")
        XCTAssertNil(LanguagePolicy.alternate(for: result))
    }

    func testCyrillicLettersDoNotOverrideOtherReportedLanguages() {
        for (text, language) in [("България е красива.", "bg"), ("Кыргызстандын тоолору", "ky")] {
            let result = transcript(text, language: language)
            XCTAssertNil(LanguagePolicy.alternate(for: result))
            XCTAssertNil(LanguagePolicy.alternate(for: result, expected: language))
            XCTAssertEqual(LanguagePolicy.adjustedScore(result, requested: language), result.score)
        }
    }

    func testRememberedLanguageSkipsTheSecondDecode() {
        let result = transcript("Добрий день", language: "uk")
        XCTAssertNil(LanguagePolicy.alternate(for: result, expected: "uk"))
    }

    func testRememberedLanguageIsCheckedWhenDetectionDisagrees() {
        let result = transcript("Добрий день", language: "uk")
        XCTAssertEqual(LanguagePolicy.alternate(for: result, expected: "ru"), "ru")
    }

    func testMismatchedScriptIsPenalised() {
        let russianTextDecodedAsUkrainian = transcript("Это был съёмочный день", language: "ru", score: 0.9)
        let ukrainian = transcript("Це був знімальний день", language: "uk", score: 0.85)

        let russianScore = LanguagePolicy.adjustedScore(russianTextDecodedAsUkrainian, requested: "uk")
        let ukrainianScore = LanguagePolicy.adjustedScore(ukrainian, requested: "uk")
        XCTAssertGreaterThan(ukrainianScore, russianScore)
    }
}

final class CleanupGuardTests: XCTestCase {
    func testCleanupPromptUsesSourceLanguageWithoutForcingTranslation() {
        XCTAssertEqual(TextLanguage.source(in: "короткий", reported: "uk-UA"), "uk")
        XCTAssertEqual(TextLanguage.source(in: "слово", reported: "Russian"), "ru")
        XCTAssertEqual(TextLanguage.source(in: "Її текст написано українською мовою.", reported: "unknown"), "uk")
        XCTAssertNil(TextLanguage.source(in: "OK", reported: "auto"))

        let prompt = CleanupPipeline.systemPrompt(sourceLanguage: "uk")
        XCTAssertTrue(prompt.contains("Likely source language: Ukrainian"))
        XCTAssertTrue(prompt.contains("mixed-language speech and quotations"))
        XCTAssertTrue(prompt.contains("original transcript unchanged"))
        XCTAssertTrue(CleanupPipeline.systemPrompt(sourceLanguage: nil).contains("infer its language when clear"))
    }

    func testTranslationIsRejected() {
        XCTAssertFalse(CleanupGuard.isAcceptable(
            input: "Привіт, як справи?",
            output: "Hello, how are you?"
        ))
    }

    func testSameLanguageCleanupIsAccepted() {
        XCTAssertTrue(CleanupGuard.isAcceptable(
            input: "привіт як справи",
            output: "Привіт, як справи?"
        ))
    }

    func testDroppedContentIsRejected() {
        let input = "This is a long dictation sentence that contains several important details and should not be shortened."
        XCTAssertFalse(CleanupGuard.isAcceptable(input: input, output: "This is a dictation."))
    }

    func testRefusalIsRejected() {
        XCTAssertFalse(CleanupGuard.isAcceptable(
            input: "Hello world",
            output: "I'm sorry, I cannot help with that."
        ))
    }

    func testCodeFenceIsStripped() {
        XCTAssertEqual(CleanupGuard.normalize("```\nHello world\n```"), "Hello world")
    }

    func testPreambleIsStripped() {
        XCTAssertEqual(CleanupGuard.normalize("Ось виправлений текст:\nПривіт, як справи?"),
                       "Привіт, як справи?")
    }

    func testWrappingQuotesAreStripped() {
        XCTAssertEqual(CleanupGuard.normalize("\"Hello world\""), "Hello world")
    }
}

final class PlausibilityTests: XCTestCase {
    func testKnownHallucinationsAreRejected() {
        XCTAssertFalse(Plausibility.isAcceptable("Thanks for watching!"))
        XCTAssertFalse(Plausibility.isAcceptable("Продолжение следует..."))
    }

    func testShortRealAnswerIsAccepted() {
        for phrase in ["Так", "Thank you.", "Bye", "好的", "OK"] {
            XCTAssertTrue(Plausibility.isAcceptable(phrase))
        }
    }

    func testEmptyIsRejected() {
        XCTAssertFalse(Plausibility.isAcceptable("   "))
    }

    func testNonSpeechAnnotationsAreRejected() {
        for marker in ["...", "♪", " [Music] ", "[applause]", "(music)"] {
            XCTAssertFalse(Plausibility.isAcceptable(marker))
        }
    }
}

final class SelectionEditorTests: XCTestCase {
    func testDeleteKeywordMeansRemoval() {
        XCTAssertEqual(SelectionEditor.normalize("DELETE", selection: "some long text")?.text, "")
    }

    func testEmptyAnswerIsAFailureNotADeletion() {
        XCTAssertNil(SelectionEditor.normalize("   ", selection: "text"))
    }

    func testModelCanDeleteOnlyWithACompleteDeletionInstruction() {
        XCTAssertEqual(SelectionEditor.validatedAnswer("DELETE", selection: "some text", instruction: "Видали це.")?.text, "")
        XCTAssertEqual(SelectionEditor.validatedAnswer("DELETE", selection: "some text", instruction: "Delete it.")?.text, "")
        XCTAssertNil(SelectionEditor.validatedAnswer("DELETE", selection: "some text", instruction: "fix the spelling"))
        XCTAssertNil(SelectionEditor.validatedAnswer("DELETE", selection: "some text", instruction: "delete the final word"))
        XCTAssertNil(SelectionEditor.validatedAnswer("Fix this", selection: "some text", instruction: "fix this"))
    }

    func testWrappingQuotesAreStripped() {
        XCTAssertEqual(SelectionEditor.normalize("\"Hello\"", selection: "Привет")?.text, "Hello")
    }

    func testImplausibleShorteningIsRejected() {
        let selection = String(repeating: "word ", count: 60)
        XCTAssertNil(SelectionEditor.normalize("ok", selection: selection))
    }
}

final class TranslatorTests: XCTestCase {
    func testLanguageNames() {
        XCTAssertEqual(Translator.languageName("uk"), "Ukrainian")
        XCTAssertEqual(Translator.languageName("en"), "English")
        XCTAssertEqual(Translator.languageName("ru"), "Russian")
        XCTAssertEqual(Translator.languageName("pl"), "Polish")
    }
}

@MainActor
final class AppPresentationTests: XCTestCase {
    func testDockAndAboutShowThePackagedIcon() throws {
        let file = try XCTUnwrap(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let bundled = try XCTUnwrap(NSImage(contentsOf: file))
        XCTAssertEqual(TacetIcon.image.tiffRepresentation, bundled.tiffRepresentation)

        let reference = try iconPixels(bundled)
        let dock = try iconPixels(NSApp.applicationIconImage)
        let meanDifference = zip(reference, dock).reduce(0.0) { sum, pixels in
            sum + Double(abs(Int(pixels.0) - Int(pixels.1)))
        } / Double(reference.count)
        XCTAssertLessThan(meanDifference, 3, "Dock generated a visibly different icon")
    }

    func testMenuBarMarksUseSystemTint() {
        for mark in MenuBarMark.allCases {
            XCTAssertTrue(mark.image.isTemplate)
            XCTAssertEqual(mark.image.size, NSSize(width: 21, height: 15))
        }
    }

    func testPreviewDoesNotDismissAnActiveRecording() async throws {
        let hud = HUDController.shared
        defer { hud.hide() }
        hud.showRecording(theme: .glass)
        let window = try XCTUnwrap(hud.previewWindow)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)

        hud.preview()
        try await Task.sleep(for: .milliseconds(3_300))
        XCTAssertTrue(hud.previewWindow?.isVisible == true)
    }

    func testWaveformShowsQuietSpeechAndResetsWhenStopped() async throws {
        XCTAssertEqual(AudioCaptureService.meterLevel(forPeak: 0), 0)
        XCTAssertEqual(AudioCaptureService.meterLevel(forPeak: .nan), 0)
        XCTAssertEqual(AudioCaptureService.meterLevel(forPeak: 1), 1)

        let waveform = WaveformModel(barCount: 5)
        defer { waveform.stop() }
        waveform.start()
        waveform.setLevel(AudioCaptureService.meterLevel(forPeak: 0.01))
        XCTAssertGreaterThan(waveform.heights.max() ?? 0, 2.0 / 22.0)

        waveform.setLevel(0)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThan(waveform.heights.max() ?? 1, 2.0 / 22.0)
        waveform.stop()
        XCTAssertTrue(waveform.heights.allSatisfy { $0 == 0 })
    }

    func testProcessingIndicatorClosesImmediatelyOnSuccessAndStaysVisibleOnError() {
        let hud = HUDController.shared
        defer { hud.hide() }

        hud.showProcessing(theme: .glass)
        XCTAssertTrue(hud.previewWindow?.isVisible == true)
        hud.finish(error: nil)
        XCTAssertFalse(hud.previewWindow?.isVisible == true)

        hud.showProcessing(theme: .glass)
        hud.finish(error: "Not transcribed, recording kept")
        XCTAssertTrue(hud.previewWindow?.isVisible == true)
        XCTAssertEqual(hud.previewWindow?.alphaValue, 1)
    }

    func testLiveIndicatorOrdersEveryDisplayAndDoesNotReappearAfterHiding() async throws {
        let hud = HUDController.shared
        defer { hud.hide() }
        hud.showRecording(theme: .glass)

        for screen in NSScreen.screens {
            let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            let panel = try XCTUnwrap(hud.panels[id.uint32Value])
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(panel.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications]))
            XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
            panel.orderOut(nil)
        }

        let workspace = NSWorkspace.shared
        workspace.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: workspace)
        XCTAssertTrue(hud.panels.values.allSatisfy(\.isVisible))
        hud.hide()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(hud.panels.values.contains(where: \.isVisible))
    }

    private func iconPixels(_ image: NSImage) throws -> [UInt8] {
        let side = 48
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        context.cgContext.clear(rect)
        image.draw(in: rect)
        let data = try XCTUnwrap(bitmap.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: side * side * 4))
    }
}

final class AudioChunkTests: XCTestCase {
    private func makeClip(seconds: Double) -> AudioClip {
        let count = Int(seconds * 16_000)
        let samples = (0..<count).map { Float(sin(Double($0) * 0.01) * 0.2) }
        return AudioClip(url: URL(fileURLWithPath: "/tmp/tacet-none.wav"),
                         duration: seconds,
                         samples: samples)
    }

    func testShortAudioIsNotSplit() {
        let clip = makeClip(seconds: 5)
        XCTAssertEqual(clip.chunked(seconds: 10).count, 1)
    }

    func testLongAudioIsSplitIntoPieces() {
        let clip = makeClip(seconds: 30)
        let chunks = clip.chunked(seconds: 10)

        defer { chunks.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.samples.count }, clip.samples.count)
        for chunk in chunks {
            XCTAssertGreaterThan(chunk.duration, 0)
            XCTAssertLessThanOrEqual(chunk.duration, 10)
        }
    }

    func testLongRecordingCannotReturnAnOversizedTail() {
        let samples = [Float](repeating: 0.2, count: 601 * 16_000)
        let clip = AudioClip(url: URL(fileURLWithPath: "/tmp/tacet-original.wav"), duration: 601, samples: samples)
        let chunks = clip.chunked(seconds: 480)
        defer { chunks.filter { $0.url != clip.url }.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.duration <= 480 && $0.url != clip.url })
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.samples.count }, samples.count)
    }
}

final class WavRepairTests: XCTestCase {
    func testValidTrailingMetadataIsPreserved() throws {
        let wave = makeWave(audio: Data(repeating: 16, count: 8), trailing: Data("LIST\u{04}\0\0\0INFO".utf8))
        try withTemporaryFile(wave) { url in
            XCTAssertFalse(WavRepair.repairIfNeeded(url: url))
            XCTAssertEqual(try Data(contentsOf: url), wave)
        }
    }

    func testInterruptedPCMHeaderIsRecovered() throws {
        let complete = makeWave(audio: Data(repeating: 16, count: 20), ancillary: Data("JUNK\u{04}\0\0\0data".utf8))
        var interrupted = complete
        interrupted.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        interrupted.replaceSubrange(52..<56, with: [0, 0, 0, 0])
        try withTemporaryFile(interrupted) { url in
            XCTAssertTrue(WavRepair.repairIfNeeded(url: url))
            XCTAssertEqual(try Data(contentsOf: url), complete)
        }
    }

    func testNonWavInputIsNeverModified() throws {
        let bytes = Data(("not a waveform with a data marker " + String(repeating: "a", count: 40)).utf8)
        try withTemporaryFile(bytes) { url in
            XCTAssertFalse(WavRepair.repairIfNeeded(url: url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    private func makeWave(audio: Data, ancillary: Data = Data(), trailing: Data = Data()) -> Data {
        let format = Data([1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0])
        let body = Data("WAVEfmt \u{10}\0\0\0".utf8) + format + ancillary + Data("data".utf8)
            + size(audio.count) + audio + trailing
        return Data("RIFF".utf8) + size(body.count) + body
    }

    private func size(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
    }

    private func withTemporaryFile(_ data: Data, run: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        try run(url)
    }
}
