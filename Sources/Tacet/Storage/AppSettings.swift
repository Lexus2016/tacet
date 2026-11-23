import Foundation
import SwiftUI

/// User-facing configuration. Everything here is persisted in UserDefaults;
/// API keys are NOT stored here, they live in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: Language

    /// "auto" or an ISO 639-1 code. Auto detects the language of every dictation
    /// separately, so switching chats does not require switching settings.
    @Published var languageMode: String {
        didSet { defaults.set(languageMode, forKey: "languageMode") }
    }

    /// Runs a second decode when Ukrainian and Russian could be confused.
    @Published var dualLanguageCheck: Bool {
        didSet { defaults.set(dualLanguageCheck, forKey: "dualLanguageCheck") }
    }

    /// Asks a voice-based language detector (Gemini Decision via OpenRouter)
    /// which language is actually spoken.
    @Published var voiceLanguageCheck: Bool {
        didSet { defaults.set(voiceLanguageCheck, forKey: "voiceLanguageCheck") }
    }

    @Published var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: "openRouterModel") }
    }

    // MARK: Engines

    /// Ordered engine identifiers. The first one that returns a plausible
    /// transcript wins; the rest are fallbacks.
    @Published var engineOrder: [String] {
        didSet { defaults.set(engineOrder, forKey: "engineOrder") }
    }

    @Published var groqModel: String {
        didSet { defaults.set(groqModel, forKey: "groqModel") }
    }

    @Published var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") }
    }

    @Published var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: "openAIModel") }
    }

    @Published var cloudTimeout: Double {
        didSet { defaults.set(cloudTimeout, forKey: "cloudTimeout") }
    }

    // MARK: Cleanup

    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }

    @Published var cleanupProvider: String {
        didSet { defaults.set(cleanupProvider, forKey: "cleanupProvider") }
    }

    /// Chat model per provider. One provider may be used for cleanup and
    /// another for dictation, so the model is stored per provider, not globally.
    @Published var chatModels: [String: String] {
        didSet { defaults.set(chatModels, forKey: "chatModels") }
    }

    func chatModel(for provider: String) -> String {
        let stored = chatModels[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? ProviderCatalog.defaultChatModel(for: provider) : stored
    }

    func setChatModel(_ model: String, for provider: String) {
        chatModels[provider] = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Published var cleanupBaseURL: String {
        didSet { defaults.set(cleanupBaseURL, forKey: "cleanupBaseURL") }
    }

    @Published var cleanupTimeout: Double {
        didSet { defaults.set(cleanupTimeout, forKey: "cleanupTimeout") }
    }

    // MARK: Behaviour

    @Published var pasteAutomatically: Bool {
        didSet { defaults.set(pasteAutomatically, forKey: "pasteAutomatically") }
    }

    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: "playSounds") }
    }

    /// "bundled" (the TypeWhisper cues) or "system".
    @Published var soundStyle: String {
        didSet { defaults.set(soundStyle, forKey: "soundStyle") }
    }

    /// "island", "notch", "overlay" or "minimal".
    @Published var indicatorStyle: String {
        didSet { defaults.set(indicatorStyle, forKey: "indicatorStyle") }
    }

    /// "auto" keeps the spoken language; a code translates the transcript
    /// before it is inserted.
    @Published var outputLanguage: String {
        didSet { defaults.set(outputLanguage, forKey: "outputLanguage") }
    }

    @Published var showHUD: Bool {
        didSet { defaults.set(showHUD, forKey: "showHUD") }
    }

    @Published var keepAudioDays: Int {
        didSet { defaults.set(keepAudioDays, forKey: "keepAudioDays") }
    }

    // MARK: Hotkey

    @Published var hotkeyMode: String {
        didSet { defaults.set(hotkeyMode, forKey: "hotkeyMode") }
    }

    @Published var hotkeyKeyCode: Int {
        didSet { defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }

    @Published var hotkeyModifiers: Int {
        didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    /// Human-readable name of the recorded key, e.g. "Space" or "K".
    @Published var hotkeyLabel: String {
        didSet { defaults.set(hotkeyLabel, forKey: "hotkeyLabel") }
    }

    // MARK: Derived

    var languageOverride: String? {
        languageMode == "auto" ? nil : languageMode
    }

    var isCleanupConfigured: Bool {
        cleanupEnabled && !chatModel(for: cleanupProvider).isEmpty
    }

    // MARK: Init

    private init() {
        languageMode = defaults.string(forKey: "languageMode") ?? "auto"
        dualLanguageCheck = defaults.object(forKey: "dualLanguageCheck") as? Bool ?? true
        voiceLanguageCheck = defaults.object(forKey: "voiceLanguageCheck") as? Bool ?? false
        openRouterModel = defaults.string(forKey: "openRouterModel") ?? "google/gemini-decision-1"
        engineOrder = defaults.stringArray(forKey: "engineOrder") ?? ["groq", "parakeet", "openai"]
        groqModel = defaults.string(forKey: "groqModel") ?? "whisper-large-v3-turbo"
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        openAIModel = defaults.string(forKey: "openAIModel") ?? "whisper-1"
        cloudTimeout = defaults.object(forKey: "cloudTimeout") as? Double ?? 20
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        cleanupProvider = defaults.string(forKey: "cleanupProvider") ?? "groq"

        var models = defaults.dictionary(forKey: "chatModels") as? [String: String] ?? [:]
        if let legacy = defaults.string(forKey: "cleanupModel"), !legacy.isEmpty, models["groq"] == nil {
            // Keep a value the user actually chose; ignore the old default so
            // the faster default applies.
            if legacy != "llama-3.3-70b-versatile" {
                models["groq"] = legacy
            }
        }
        chatModels = models
        cleanupBaseURL = defaults.string(forKey: "cleanupBaseURL") ?? "https://api.groq.com/openai/v1"
        cleanupTimeout = defaults.object(forKey: "cleanupTimeout") as? Double ?? 1.5
        pasteAutomatically = defaults.object(forKey: "pasteAutomatically") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        soundStyle = defaults.string(forKey: "soundStyle") ?? "bundled"
        indicatorStyle = defaults.string(forKey: "indicatorStyle") ?? "island"
        outputLanguage = defaults.string(forKey: "outputLanguage") ?? "auto"
        showHUD = defaults.object(forKey: "showHUD") as? Bool ?? true
        keepAudioDays = defaults.object(forKey: "keepAudioDays") as? Int ?? 7
        hotkeyMode = defaults.string(forKey: "hotkeyMode") ?? "hold"
        hotkeyKeyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int ?? 49
        hotkeyModifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? 0x1800 // control + option
        hotkeyLabel = defaults.string(forKey: "hotkeyLabel") ?? "Space"
    }
}

/// Engine identifiers used across settings, the pipeline and the UI.
enum EngineID {
    static let groq = "groq"
    static let parakeet = "parakeet"
    static let openAI = "openai"

    static func displayName(_ id: String) -> String {
        switch id {
        case groq: return "Groq (cloud)"
        case parakeet: return "Parakeet (local)"
        case openAI: return "OpenAI-compatible"
        default: return id
        }
    }
}

/// Keychain account names. The service name is shared, the accounts are per provider.
enum KeychainAccount {
    static let groq = "groq"
    static let openAI = "openai"
    static let openRouter = "openrouter"
    static let cleanup = "cleanup"
}

enum LanguageOption: String, CaseIterable, Identifiable {
    case auto
    case uk
    case ru
    case en
    case de
    case es
    case fr
    case pl
    case tr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto (per dictation)"
        case .uk: return "Ukrainian"
        case .ru: return "Russian"
        case .en: return "English"
        case .de: return "German"
        case .es: return "Spanish"
        case .fr: return "French"
        case .pl: return "Polish"
        case .tr: return "Turkish"
        }
    }
}
