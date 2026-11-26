import Foundation

/// Mandatory first-run tour on the Mac: every mode is done once by the user in a practice field.
/// Dictation outside the tour stays locked until the last step is finished.
/// Обов'язкове знайомство на Mac: кожен режим користувач один раз виконує сам у тренувальному
/// полі. Диктування поза знайомством заблоковане, доки не пройдено останній крок.
@MainActor
final class Onboarding: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case key, dictate, correct, languages, translate, edit, translateSelection, paste, history, indicator
        var id: Int { rawValue }
    }

    struct Delivery: Equatable {
        var text: String
        var raw: String
        var language: String?
        var translated = false
        var edited = false
        var pasted = false
    }

    static let shared = Onboarding()
    /// Raised when a later version adds a step, so current users see it too.
    /// Збільшується, коли наступна версія додає крок, щоб його побачили й чинні користувачі.
    static let version = 1
    private static let doneKey = "onboarding.mac.version"
    private static let stepKey = "onboarding.mac.step"

    @Published private(set) var isComplete: Bool
    @Published private(set) var step: Step
    @Published private(set) var finished: Set<Step> = []
    @Published private(set) var last: Delivery?
    @Published private(set) var languages: [String] = []
    @Published private(set) var attempts = 0
    /// True while the tour's window is the key window: only then may dictation run before the tour ends.
    /// True, поки вікно знайомства є ключовим: лише тоді диктування може працювати до його завершення.
    var windowIsKey = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.integer(forKey: Self.doneKey) >= Self.version
        step = Step(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .key
    }

    var blocksDictation: Bool { !isComplete && !windowIsKey }

    /// The tour is open and in front: its practice field is where dictated text goes, handed over
    /// directly because Tacet does not paste into its own windows.
    /// Знайомство відкрите й попереду: тренувальне поле — місце, куди потрапляє продиктований текст;
    /// його передають напряму, бо Tacet не вставляє текст у власні вікна.
    var isPracticing: Bool { !isComplete && windowIsKey }

    struct Inbound: Equatable {
        let id = UUID()
        let text: String
        let replacesAll: Bool
    }
    @Published private(set) var inbound: Inbound?

    func put(_ text: String, replacingAll: Bool) {
        inbound = Inbound(text: text, replacesAll: replacingAll)
    }
    var canContinue: Bool { finished.contains(step) }
    var isLast: Bool { step == Step.allCases.last }

    /// Requests made during the tour are marked so the gateway does not charge them to the plan.
    /// Запити під час знайомства позначаються, щоб шлюз не списував їх із тарифу.
    nonisolated static var isRunning: Bool {
        UserDefaults.standard.integer(forKey: doneKey) < version && UserDefaults.standard.bool(forKey: "onboarding.mac.open")
    }

    func windowChanged(open: Bool, key: Bool) {
        windowIsKey = key
        defaults.set(open && !isComplete, forKey: "onboarding.mac.open")
    }

    func recordingStarted() {
        guard !isComplete, step == .key else { return }
        finished.insert(.key)
    }

    func delivered(_ delivery: Delivery) {
        guard !isComplete else { return }
        last = delivery
        attempts += 1
        if let language = delivery.language, !languages.contains(language) { languages.append(language) }
        switch step {
        case .key: finished.insert(.key)
        case .dictate: if !delivery.text.isEmpty { finished.insert(.dictate) }
        // A clean phrase may need no correction; the second try completes the step either way.
        // Чиста фраза може не потребувати виправлень; друга спроба завершує крок у будь-якому разі.
        case .correct: if delivery.text != delivery.raw || attempts >= 2 { finished.insert(.correct) }
        case .languages: if languages.count >= 2 || attempts >= 3 { finished.insert(.languages) }
        case .translate: if delivery.translated { finished.insert(.translate) }
        case .edit, .translateSelection: if delivery.edited { finished.insert(step) }
        case .paste: if !delivery.pasted { finished.insert(.paste) }
        case .history, .indicator: break
        }
    }

    func note(_ step: Step) {
        guard !isComplete, self.step == step else { return }
        finished.insert(step)
    }

    func advance() {
        guard canContinue else { return }
        if let next = Step(rawValue: step.rawValue + 1) {
            move(to: next)
        } else {
            isComplete = true
            defaults.set(Self.version, forKey: Self.doneKey)
            defaults.set(false, forKey: "onboarding.mac.open")
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
        move(to: .key)
    }

    /// For rendering a step in the UI harness. / Для відтворення кроку в перевірці інтерфейсу.
    func preview(_ step: Step, sample: Delivery?) {
        finished = Set(Step.allCases.filter { $0.rawValue < step.rawValue })
        move(to: step)
        if let sample { delivered(sample) }
    }

    private func move(to next: Step) {
        // Steps already done stay done when the user goes back and forth.
        // Уже пройдені кроки лишаються пройденими, коли користувач рухається назад і вперед.
        step = next
        last = nil
        languages = []
        attempts = 0
        defaults.set(next.rawValue, forKey: Self.stepKey)
    }
}
