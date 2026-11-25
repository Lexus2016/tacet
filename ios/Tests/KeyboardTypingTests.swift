import XCTest
@testable import Tacet

final class KeyboardTypingTests: XCTestCase {
    func testSentenceCapitalizationFollowsContext() {
        let mode = KeyboardCapitalization.sentences
        XCTAssertTrue(mode.startsUppercase(after: ""))
        XCTAssertTrue(mode.startsUppercase(after: "Привіт. "))
        XCTAssertTrue(mode.startsUppercase(after: "Він сказав: «Привіт!» "))
        XCTAssertTrue(mode.startsUppercase(after: "Новий абзац\n"))
        XCTAssertTrue(mode.startsUppercase(after: "Here we go. \""))
        XCTAssertFalse(mode.startsUppercase(after: "Привіт"))
        XCTAssertFalse(mode.startsUppercase(after: "Привіт, "))
        XCTAssertFalse(mode.startsUppercase(after: "https://example."))
    }

    func testCapitalizationModesRespectTheHostField() {
        XCTAssertFalse(KeyboardCapitalization.none.startsUppercase(after: ""))
        XCTAssertTrue(KeyboardCapitalization.words.startsUppercase(after: "one "))
        XCTAssertFalse(KeyboardCapitalization.words.startsUppercase(after: "one"))
        XCTAssertTrue(KeyboardCapitalization.allCharacters.startsUppercase(after: "ABC"))
    }

    func testWordReplacementPreservesSeparatorsAndUsesGraphemes() throws {
        let current = try XCTUnwrap(KeyboardWord(before: "добрий, ‘п’яти", after: "", selection: nil))
        XCTAssertEqual(current.text, "п’яти")
        XCTAssertEqual(current.replacement("п’ятиденний"), "п’ятиденний ")

        let beforePunctuation = try XCTUnwrap(KeyboardWord(before: "say helo", after: "!", selection: ""))
        XCTAssertEqual(beforePunctuation.replacement("hello"), "hello")
        let accent = try XCTUnwrap(KeyboardWord(before: "the cafe\u{301}", after: nil, selection: nil))
        XCTAssertEqual(accent.text.count, 4)
    }

    func testSuggestionsIgnoreBlankContextAndPartialSelections() {
        XCTAssertNil(KeyboardWord(before: "some ", after: nil, selection: nil))
        XCTAssertNil(KeyboardWord(before: "old", after: "", selection: "text"))
        XCTAssertNil(KeyboardWord(before: "", after: "", selection: "two words"))
        XCTAssertNil(KeyboardWord(before: String(repeating: "a", count: 49), after: "", selection: nil))
    }

    func testSuggestionsUseWholeWordAtCursorAndPreserveSpacesAroundSelection() throws {
        let midword = try XCTUnwrap(KeyboardWord(before: "fix te", after: "h now", selection: nil))
        XCTAssertEqual(midword.text, "teh")
        XCTAssertEqual(midword.trailing, "h")
        XCTAssertEqual(midword.replacement("the"), "the")

        let beforeWord = try XCTUnwrap(KeyboardWord(before: "fix ", after: "teh now", selection: nil))
        XCTAssertEqual(beforeWord.trailing, "teh")
        XCTAssertEqual(beforeWord.text, midword.text)

        let selection = try XCTUnwrap(KeyboardWord(before: "fix ", after: ", now", selection: "teh"))
        XCTAssertTrue(selection.selected)
        XCTAssertEqual(selection.replacement("the"), "the")
    }

    func testHeldDeletionAcceleratesAndLimitsEachBatch() {
        XCTAssertEqual(KeyboardDeletion.unit(after: .milliseconds(360)), .character)
        XCTAssertEqual(KeyboardDeletion.unit(after: .seconds(2)), .word)
        XCTAssertEqual(KeyboardDeletion.unit(after: .seconds(3)), .sentence)
        XCTAssertEqual(KeyboardDeletion.unit(after: .seconds(4)), .paragraph)
        XCTAssertEqual(KeyboardDeletion.count(in: "a👨‍👩‍👧‍👦", unit: .character), 1)
        XCTAssertEqual(KeyboardDeletion.count(in: "one two ", unit: .word), 4)
        XCTAssertEqual(KeyboardDeletion.count(in: "One. Two here.", unit: .sentence), 10)
        XCTAssertEqual(KeyboardDeletion.count(in: "One.\nTwo here. Last.", unit: .paragraph), 15)
        XCTAssertEqual(KeyboardDeletion.count(in: String(repeating: "x", count: 500), unit: .paragraph), 64)
    }

    func testTrackpadClampsAndKeepsTheColumnWhenAMatchingLineExists() {
        XCTAssertEqual(KeyboardCursor.horizontalOffset(before: "a👩🏽‍💻", after: "z", steps: -5), -8)
        XCTAssertEqual(KeyboardCursor.horizontalOffset(before: "abc", after: "z", steps: 5), 1)
        XCTAssertEqual(KeyboardCursor.verticalOffset(before: "first\nab", after: "cd\nxyz", down: false), -6)
        XCTAssertEqual(KeyboardCursor.verticalOffset(before: "first\nab", after: "cd\nxyz", down: true), 5)
        XCTAssertEqual(KeyboardCursor.verticalOffset(before: "ab", after: "cd", down: true), 0)
    }

    func testTrackpadOffsetsRespectComposedCharactersAndLineBreaks() {
        XCTAssertEqual(KeyboardCursor.horizontalOffset(before: "", after: "👩🏽‍💻z", steps: 1), 7)
        XCTAssertEqual(KeyboardCursor.verticalOffset(before: "🔵abcd\r\n🤝ab", after: "", down: false), -8)
        XCTAssertEqual(KeyboardCursor.verticalOffset(before: "a", after: "b\r\n🤝cd", down: true), 5)
        XCTAssertEqual(KeyboardCursor.offset(toColumn: 1, before: "aa\n🔵🤝", after: ""), -2)
        XCTAssertEqual(KeyboardCursor.offset(toColumn: 2, before: "a", after: "🤝\nc"), 2)
    }

    func testCandidatesAreDistinctAndDictionaryMatchesOnlySelectedLanguage() throws {
        let word = try XCTUnwrap(KeyboardWord(before: "teh", after: nil, selection: nil))
        XCTAssertEqual(word.options(["teh", "", "the", "THE", "ten", "tech", "other"]), ["the", "ten", "tech"])
        let languages = ["en_GB", "en_US", "uk", "pt_BR", "ru_RU"]
        XCTAssertEqual(KeyboardWord.dictionary(for: .english, in: languages), "en_US")
        XCTAssertEqual(KeyboardWord.dictionary(for: .ukrainian, in: languages), "uk")
        XCTAssertEqual(KeyboardWord.dictionary(for: .portuguese, in: languages), "pt_BR")
        XCTAssertEqual(KeyboardWord.dictionary(for: .russian, in: languages), "ru_RU")
        XCTAssertNil(KeyboardWord.dictionary(for: .spanish, in: languages))
    }

    func testRequestedLayoutsAreAvailableAndCzechSupportsAccents() {
        let requested: Set<KeyboardLayout> = [.czech, .spanish, .portuguese, .german, .french, .italian]
        XCTAssertTrue(requested.isSubset(of: KeyboardLayout.allCases))
        XCTAssertTrue(requested.isSubset(of: KeyboardLayout.defaults))
        XCTAssertEqual(KeyboardLayout.ordered([.english, .czech]), [.english, .czech])
        XCTAssertEqual(KeyboardLayout.czech.speechLocale, "cs-CZ")
        XCTAssertTrue(KeyboardLayout.czech.letters[0].hasPrefix("qwertz"))
        XCTAssertEqual(KeyboardLayout.czech.alternatives(for: "e"), "ěé")
        XCTAssertEqual(KeyboardLayout.czech.alternatives(for: "u"), "ůú")
        XCTAssertEqual(KeyboardWord.dictionary(for: .czech, in: ["sk", "cs_CZ"]), "cs_CZ")
    }

    func testSpellingCorrectionsKeepNearbyTyposAndRejectUnrelatedWords() throws {
        let word = try XCTUnwrap(KeyboardWord(before: "teh", after: nil, selection: nil))
        XCTAssertEqual(word.corrections(["the", "THE", "ten", "technology", "today", "ten hours"]),
                       ["the", "ten"])
        let ukrainian = try XCTUnwrap(KeyboardWord(before: "првиіт", after: nil, selection: nil))
        XCTAssertEqual(ukrainian.corrections(["привіт", "вітаю", "добридень"]), ["привіт"])
    }

    func testCompletionsPreserveTheTypedPrefixAndVocabularyOrder() throws {
        let russian = try XCTUnwrap(KeyboardWord(before: "приве", after: "", selection: nil))
        XCTAssertEqual(russian.completions(["прива", "припев", "прив", "привет", "привезти", "привет", "приве!"]),
                       ["привет", "привезти"])
        let capitalized = try XCTUnwrap(KeyboardWord(before: "Приве", after: "!", selection: nil))
        XCTAssertEqual(capitalized.completions(["привет"]), ["Привет"])
        XCTAssertEqual(capitalized.replacement("Привет"), "Привет")
    }

    func testCompletionsAreLimitedToUnfinishedWordsAtTheCaret() throws {
        let selected = try XCTUnwrap(KeyboardWord(before: "", after: "", selection: "приве"))
        XCTAssertTrue(selected.completions(["привет"]).isEmpty)
        let middle = try XCTUnwrap(KeyboardWord(before: "при", after: "ве", selection: nil))
        XCTAssertTrue(middle.completions(["привет"]).isEmpty)
        let short = try XCTUnwrap(KeyboardWord(before: "пр", after: "", selection: nil))
        XCTAssertTrue(short.completions(["привет"]).isEmpty)
    }

    func testPreviewStaysOnScreenAtBothEdgesEvenInLandscape() {
        for bounds in [CGRect(x: 0, y: 0, width: 402, height: 298),
                       CGRect(x: 0, y: 0, width: 756, height: 229)] {
            let left = CGRect(x: 3, y: 34, width: 34, height: 55)
            let right = CGRect(x: bounds.width - 37, y: 34, width: 34, height: 55)
            XCTAssertEqual(KeyboardPreview.frame(above: left, inside: bounds).minX, 3)
            let preview = KeyboardPreview.frame(above: right, inside: bounds)
            XCTAssertEqual(preview.maxX, bounds.width - 3)
            XCTAssertGreaterThan(preview.width, right.width)
            XCTAssertGreaterThan(preview.height, right.height)
            XCTAssertTrue(bounds.contains(preview))
            let lowerRowKey = left.offsetBy(dx: 0, dy: 54)
            let raised = KeyboardPreview.frame(above: lowerRowKey, inside: bounds)
            XCTAssertEqual(raised.maxY, lowerRowKey.minY - 3)
        }
    }
}
