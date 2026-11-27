import Foundation

/// What one dictation produced, for the first-run tour to read.
/// Що дало одне диктування, щоб знайомство могло це прочитати.
struct DictationDelivery: Equatable {
    var id = UUID()
    var text: String
    var raw: String
    var language: String?
    var translated = false
    var edited = false
}

/// The user's agreement that audio and selected text go to third-party AI models through Tacet.
/// Nothing is sent before it is given (App Store Review Guideline 5.1.2(i)).
/// Згода користувача на те, що звук і виділений текст через Tacet передаються стороннім моделям ШІ.
/// До неї нічого не надсилається.
enum MobileConsent {
    static let key = "consent.thirdPartyAI.v1"
    static var isGiven: Bool { UserDefaults.standard.bool(forKey: key) }
    static func give() { UserDefaults.standard.set(true, forKey: key) }
    static func withdraw() { UserDefaults.standard.set(false, forKey: key) }
}

/// Mandatory first-run tour on the iPhone: each mode is done once by the user in a practice field.
/// Voice features stay locked until the last step is finished.
/// Обов'язкове знайомство на iPhone: кожен режим користувач один раз виконує сам у тренувальному полі.
/// Голосові функції заблоковані, доки не пройдено останній крок.
@MainActor
final class MobileOnboarding: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case keyboard, session, dictate, correct, languages, translate, edit, translateSelection, typing
        var id: Int { rawValue }
    }

    static let shared = MobileOnboarding()
    /// Raised when a later version adds a step, so current users see it too.
    /// Збільшується, коли наступна версія додає крок, щоб його побачили й чинні користувачі.
    static let version = 1
    static let keyboardBundle = "ua.rawira.tacet.ios.keyboard"
    /// The misspelled word of the typing step and its fix, chosen from the layouts the user has.
    /// Слово з помилкою для кроку про набір і його виправлення, залежно від розкладок користувача.
    static let typo = "Приввіт"
    static let correction = "Привіт"
    @Published private(set) var typoPair: (typo: String, correction: String) = (typo, correction)
    var typoSample: String { typoPair.typo }

    func configureTyping(layouts: [KeyboardLayout]) {
        if layouts.contains(.ukrainian) { typoPair = (Self.typo, Self.correction) }
        else if layouts.contains(.english) { typoPair = ("Helo", "Hello") }
    }
    private static let doneKey = "onboarding.ios.version"
    private static let stepKey = "onboarding.ios.step"
    private static let openKey = "onboarding.ios.open"

    @Published private(set) var isComplete: Bool
    @Published private(set) var step: Step
    @Published private(set) var finished: Set<Step> = []
    @Published private(set) var last: DictationDelivery?
    @Published private(set) var languages: [String] = []
    @Published private(set) var attempts = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.integer(forKey: Self.doneKey) >= Self.version
        step = Step(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .keyboard
    }

    var canContinue: Bool { finished.contains(step) }
    var isLast: Bool { step == Step.allCases.last }

    /// Requests made during the tour are marked so the gateway does not charge them to the plan.
    /// Запити під час знайомства позначаються, щоб шлюз не списував їх із тарифу.
    nonisolated static var isRunning: Bool {
        UserDefaults.standard.integer(forKey: doneKey) < version && UserDefaults.standard.bool(forKey: openKey)
    }

    func screenChanged(visible: Bool) {
        defaults.set(visible && !isComplete, forKey: Self.openKey)
    }

    /// The Tacet keyboard is listed among the enabled keyboards. The list is a public setting of the system.
    /// Клавіатура Tacet є серед увімкнених. Список — відкрите системне налаштування.
    nonisolated static func keyboardEnabled(in list: Any?) -> Bool {
        (list as? [String])?.contains { $0.hasPrefix(keyboardBundle) } ?? false
    }

    func refreshKeyboard() {
        if Self.keyboardEnabled(in: UserDefaults.standard.object(forKey: "AppleKeyboards")) { note(.keyboard) }
    }

    func note(_ step: Step) {
        guard !isComplete, self.step == step else { return }
        finished.insert(step)
    }

    func delivered(_ delivery: DictationDelivery) {
        guard !isComplete, last?.id != delivery.id else { return }
        last = delivery
        attempts += 1
        if let language = TextLanguage.consistent(delivery.language, with: delivery.text),
           !languages.contains(language) { languages.append(language) }
        switch step {
        case .keyboard, .session, .typing: break
        case .dictate: if !delivery.text.isEmpty { finished.insert(.dictate) }
        // A clean phrase may need no correction; the second try completes the step either way.
        // Чиста фраза може не потребувати виправлень; друга спроба завершує крок у будь-якому разі.
        case .correct: if delivery.text != delivery.raw || attempts >= 2 { finished.insert(.correct) }
        // Recognition names one language per recording, so two writing systems in one text count as two languages.
        // Розпізнавання дає одну мову на запис, тож дві писемності в одному тексті зараховуються як дві мови.
        case .languages:
            if languages.count >= 2 || TextLanguage.writingSystems(in: delivery.text).count >= 2 || attempts >= 2 {
                finished.insert(.languages)
            }
        case .translate: if delivery.translated { finished.insert(.translate) }
        case .edit, .translateSelection: if delivery.edited { finished.insert(step) }
        }
    }

    /// The typing step passes when the typo was replaced with the corrected word.
    /// Крок про набір пройдено, коли слово з помилкою замінено виправленим.
    func practiceChanged(_ text: String) {
        guard step == .typing, !finished.contains(.typing) else { return }
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: { $0.caseInsensitiveCompare(typoPair.correction) == .orderedSame }),
           !words.contains(where: { $0.caseInsensitiveCompare(typoPair.typo) == .orderedSame }) {
            finished.insert(.typing)
        }
    }

    func advance() {
        guard canContinue else { return }
        if let next = Step(rawValue: step.rawValue + 1) {
            move(to: next)
        } else {
            isComplete = true
            defaults.set(Self.version, forKey: Self.doneKey)
            defaults.set(false, forKey: Self.openKey)
        }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { move(to: previous) }
    }

    /// From Settings: walk through the tour again. / Із налаштувань: пройти знайомство ще раз.
    func restart() {
        defaults.set(0, forKey: Self.doneKey)
        isComplete = false
        finished = []
        move(to: .keyboard)
    }

    /// For rendering a step in screenshots and UI checks. / Для відтворення кроку на знімках і в перевірках інтерфейсу.
    func preview(_ step: Step, sample: DictationDelivery?) {
        isComplete = false
        finished = Set(Step.allCases.filter { $0.rawValue < step.rawValue })
        move(to: step)
        if let sample { delivered(sample) }
    }

    private func move(to next: Step) {
        step = next
        last = nil
        languages = []
        attempts = 0
        defaults.set(next.rawValue, forKey: Self.stepKey)
    }
}
