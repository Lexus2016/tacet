import XCTest
@testable import Tacet

@MainActor
final class MobileOnboardingTests: XCTestCase {
    private func tour(step: MobileOnboarding.Step = .keyboard) -> MobileOnboarding {
        let defaults = UserDefaults(suiteName: "tour-\(UUID().uuidString)")!
        let tour = MobileOnboarding(defaults: defaults)
        if step != .keyboard { tour.preview(step, sample: nil) }
        return tour
    }

    func testKeyboardStepReadsTheSystemKeyboardList() {
        XCTAssertTrue(MobileOnboarding.keyboardEnabled(in: ["en_US@sw=QWERTY", "ua.rawira.tacet.ios.keyboard"]))
        XCTAssertFalse(MobileOnboarding.keyboardEnabled(in: ["en_US@sw=QWERTY"]))
        XCTAssertFalse(MobileOnboarding.keyboardEnabled(in: nil))
    }

    func testEachStepFinishesOnlyWithItsOwnAction() {
        let t = tour(step: .dictate)
        t.delivered(DictationDelivery(text: "", raw: "", language: nil))
        XCTAssertFalse(t.canContinue)
        t.delivered(DictationDelivery(text: "Hello", raw: "hello", language: "en"))
        XCTAssertTrue(t.canContinue)

        let correct = tour(step: .correct)
        correct.delivered(DictationDelivery(text: "Same.", raw: "Same.", language: "en"))
        XCTAssertFalse(correct.canContinue)
        // A phrase that needed no correction still passes on the second try.
        correct.delivered(DictationDelivery(text: "Same too.", raw: "Same too.", language: "en"))
        XCTAssertTrue(correct.canContinue)

        let translate = tour(step: .translate)
        translate.delivered(DictationDelivery(text: "Hola", raw: "Hello", language: "en"))
        XCTAssertFalse(translate.canContinue)
        translate.delivered(DictationDelivery(text: "Hola", raw: "Hello", language: "en", translated: true))
        XCTAssertTrue(translate.canContinue)

        let edit = tour(step: .edit)
        edit.delivered(DictationDelivery(text: "Short.", raw: "Make it shorter", language: "en", edited: true))
        XCTAssertTrue(edit.canContinue)
    }

    func testLanguagesStepNeedsTwoLanguagesOrASecondTry() {
        let t = tour(step: .languages)
        t.delivered(DictationDelivery(text: "Good morning!", raw: "Good morning!", language: "en"))
        XCTAssertFalse(t.canContinue)
        t.delivered(DictationDelivery(text: "¡Buenos días!", raw: "¡Buenos días!", language: "es"))
        XCTAssertTrue(t.canContinue)
    }

    func testTypingStepPassesOnlyWhenTheTypoWasReplacedByTheFix() {
        let t = tour(step: .typing)
        t.configureTyping(layouts: [.ukrainian, .english])
        XCTAssertEqual(t.typoSample, "Приввіт")
        t.practiceChanged("Приввіт")
        XCTAssertFalse(t.canContinue)
        t.practiceChanged("")
        XCTAssertFalse(t.canContinue)
        t.practiceChanged("Привіт")
        XCTAssertTrue(t.canContinue)

        let english = tour(step: .typing)
        english.configureTyping(layouts: [.english, .german])
        XCTAssertEqual(english.typoSample, "Helo")
        english.practiceChanged("Hello")
        XCTAssertTrue(english.canContinue)
    }

    func testTourCompletesOnlyAfterTheLastStepAndResumesWhereItStopped() {
        let defaults = UserDefaults(suiteName: "tour-\(UUID().uuidString)")!
        let t = MobileOnboarding(defaults: defaults)
        XCTAssertFalse(t.isComplete)
        t.advance()                      // blocked: the first step is not done
        XCTAssertEqual(t.step, .keyboard)
        t.note(.keyboard)
        t.advance()
        XCTAssertEqual(t.step, .session)
        // A new instance resumes at the saved step.
        XCTAssertEqual(MobileOnboarding(defaults: defaults).step, .session)
        t.preview(.typing, sample: nil)
        t.note(.typing)
        t.advance()
        XCTAssertTrue(t.isComplete)
        XCTAssertTrue(MobileOnboarding(defaults: defaults).isComplete)
        t.restart()
        XCTAssertFalse(t.isComplete)
    }

    func testConsentIsExplicitAndRevocable() {
        let saved = MobileConsent.isGiven
        defer { saved ? MobileConsent.give() : MobileConsent.withdraw() }
        MobileConsent.withdraw()
        XCTAssertFalse(MobileConsent.isGiven)
        MobileConsent.give()
        XCTAssertTrue(MobileConsent.isGiven)
        MobileConsent.withdraw()
        XCTAssertFalse(MobileConsent.isGiven)
        XCTAssertEqual(MobileDictationError.consentRequired.errorDescription != nil, true)
    }
}
