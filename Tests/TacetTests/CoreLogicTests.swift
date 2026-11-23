import XCTest
@testable import Tacet

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

    func testMismatchedScriptIsPenalised() {
        let russianTextDecodedAsUkrainian = transcript("Это был съёмочный день", language: "ru", score: 0.9)
        let ukrainian = transcript("Це був знімальний день", language: "uk", score: 0.85)

        let russianScore = LanguagePolicy.adjustedScore(russianTextDecodedAsUkrainian, requested: "uk")
        let ukrainianScore = LanguagePolicy.adjustedScore(ukrainian, requested: "uk")
        XCTAssertGreaterThan(ukrainianScore, russianScore)
    }
}

final class CleanupGuardTests: XCTestCase {
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
        XCTAssertFalse(Plausibility.isAcceptable("Thank you.", duration: 4))
        XCTAssertFalse(Plausibility.isAcceptable("Продолжение следует...", duration: 4))
    }

    func testShortRealAnswerIsAccepted() {
        XCTAssertTrue(Plausibility.isAcceptable("Так", duration: 0.6))
    }

    func testEmptyIsRejected() {
        XCTAssertFalse(Plausibility.isAcceptable("   ", duration: 1))
    }

    func testTooFewCharactersForLongAudioIsRejected() {
        XCTAssertFalse(Plausibility.isAcceptable("ok", duration: 5))
    }
}
