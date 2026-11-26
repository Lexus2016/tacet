import Foundation

/// Fetches the Tacet Solo model in the background, so on-device dictation is ready before it is
/// needed. Automatic on Wi-Fi; on a metered connection the iPhone asks once and the Mac waits.
/// Завантажує модель Tacet Solo у фоні, щоб диктування на пристрої було готове до того, як воно
/// знадобиться. Через Wi-Fi — автоматично; через лімітоване з'єднання iPhone питає один раз, а Mac чекає.
@MainActor
final class SoloDownload: ObservableObject {
    enum Phase: Equatable { case absent, downloading, ready }
    enum Action: Equatable { case none, download, ask }

    static let shared = SoloDownload()

    @Published private(set) var phase: Phase = .absent
    @Published private(set) var error: String?

    /// The languages this user dictates in. Chinese needs a second model of about 230 MB, fetched
    /// only for those who use it.
    /// Мови, якими диктує цей користувач. Для китайської потрібна друга модель на близько 230 МБ,
    /// яку завантажуємо лише тим, хто нею користується.
    var languages: Set<String> = [] {
        didSet { if phase != .downloading { phase = isComplete ? .ready : .absent } }
    }

    private var needsChinese: Bool { !languages.isDisjoint(with: SenseVoiceEngine.languages) }
    /// Languages served by the system's own dictation, whose assets the system downloads.
    /// Мови, які обслуговує системне диктування; його ресурси завантажує сама система.
    private var systemLanguages: [String] { languages.intersection(AppleDictationEngine.languages).sorted() }
    private var isComplete: Bool {
        ParakeetRecognizer.shared.isConfigured() && (!needsChinese || SenseVoiceEngine.shared.isReady())
            && systemLanguages.allSatisfy(AppleDictationEngine.isReady)
    }

    private init() { phase = isComplete ? .ready : .absent }

    private let defaults = UserDefaults.standard
    private static let removedKey = "solo.removedByUser"
    private static let meteredKey = "solo.meteredAllowed"

    /// What to do on app start. A model the user removed is never fetched again on its own.
    /// Що робити під час запуску. Модель, яку користувач вилучив, сама знову не завантажується.
    nonisolated static func action(ready: Bool, connected: Bool, removedByUser: Bool, metered: Bool,
                                   meteredAnswer: Bool?, canAsk: Bool) -> Action {
        guard !ready, connected, !removedByUser else { return .none }
        guard metered else { return .download }
        if let meteredAnswer { return meteredAnswer ? .download : .none }
        return canAsk ? .ask : .none
    }

    /// Starts the download when appropriate; returns true when the user must be asked first.
    /// Запускає завантаження, коли це доречно; повертає true, якщо спершу треба спитати користувача.
    func startIfAppropriate(connected: Bool, canAsk: Bool) async -> Bool {
        guard phase == .absent else { return false }
        let network = CloudAvailability.shared
        // Give the system a moment to evaluate the network path after launch.
        // Даємо системі мить оцінити мережевий шлях після запуску.
        for _ in 0..<10 where !network.isEvaluated { try? await Task.sleep(for: .milliseconds(200)) }
        guard network.isEvaluated, network.blocked() == nil else { return false }
        let answer = defaults.object(forKey: Self.meteredKey) as? Bool
        switch Self.action(ready: isComplete, connected: connected,
                           removedByUser: defaults.bool(forKey: Self.removedKey), metered: network.isMetered,
                           meteredAnswer: answer, canAsk: canAsk) {
        case .none: return false
        case .ask: return true
        case .download:
            download()
            return false
        }
    }

    /// The limit was reached and Solo is not on the device yet: fetch it now, under the same rules
    /// as the background download. Returns the text to show when a download is under way.
    /// Ліміт вичерпано, а Solo ще немає на пристрої: завантажуємо зараз за тими самими правилами,
    /// що й у фоні. Повертає текст для показу, якщо завантаження триває.
    func startAfterLimit() -> String? {
        if phase == .absent {
            let network = CloudAvailability.shared
            let action = Self.action(ready: isComplete, connected: true,
                                     removedByUser: defaults.bool(forKey: Self.removedKey), metered: network.isMetered,
                                     meteredAnswer: defaults.object(forKey: Self.meteredKey) as? Bool, canAsk: false)
            if action == .download { download() }
        }
        return phase == .downloading ? String(localized: "Limit reached. Tacet Solo is downloading; try again in a minute.") : nil
    }

    /// Records the answer to the metered-connection question and acts on it.
    /// Запам'ятовує відповідь на питання про лімітоване з'єднання й діє відповідно.
    func answerMetered(allow: Bool) {
        defaults.set(allow, forKey: Self.meteredKey)
        if allow { download() }
    }

    func download() {
        guard phase != .downloading else { return }
        defaults.set(false, forKey: Self.removedKey)
        phase = .downloading
        error = nil
        Task {
            do {
                if !ParakeetRecognizer.shared.isConfigured() {
                    try await ParakeetRecognizer.shared.downloadIfNeeded()
                    await ParakeetRecognizer.shared.unload()
                }
                if needsChinese, !SenseVoiceEngine.shared.isReady() { try await SenseVoiceEngine.shared.download() }
                for language in systemLanguages where !AppleDictationEngine.isReady(language) {
                    try await AppleDictationEngine.download(language)
                }
                phase = isComplete ? .ready : .absent
            } catch {
                phase = isComplete ? .ready : .absent
                self.error = error.localizedDescription
            }
        }
    }

    func remove() {
        defaults.set(true, forKey: Self.removedKey)
        Task {
            await ParakeetRecognizer.shared.removeModel()
            phase = isComplete ? .ready : .absent
        }
    }
}
