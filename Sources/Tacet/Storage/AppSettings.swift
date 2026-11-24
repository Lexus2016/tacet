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

    /// Model names that providers have retired. Treating them as unset keeps
    /// cleanup and translation working after an upstream catalogue change.
    private static let retiredModels: Set<String> = [
        "llama-3.1-8b-instant",
        "llama-3.3-70b-versatile",
    ]

    @Published var asrModels: [String: String] {
        didSet { defaults.set(asrModels, forKey: "asrModels") }
    }

    @Published var asrEnabled: [String: Bool] {
        didSet { defaults.set(asrEnabled, forKey: "asrEnabled") }
    }

    func isASREnabled(for provider: String) -> Bool {
        if provider == EngineID.parakeet { return true }
        guard ProviderCatalog.spec(provider)?.supportsTranscription == true else { return false }
        if let stored = asrEnabled[provider] { return stored }
        return provider == EngineID.groq || provider == EngineID.openAI || provider == EngineID.parakeet
    }

    func setASREnabled(_ enabled: Bool, for provider: String) {
        asrEnabled[provider] = enabled
    }

    func asrModel(for provider: String) -> String {
        let stored = asrModels[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        let legacy = provider == EngineID.groq ? groqModel : provider == EngineID.openAI ? openAIModel : ""
        return legacy.isEmpty ? ProviderCatalog.defaultASRModel(for: provider) : legacy
    }

    func setASRModel(_ model: String, for provider: String) {
        asrModels[provider] = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chatModel(for provider: String) -> String {
        let stored = chatModels[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty || Self.retiredModels.contains(stored) {
            return ProviderCatalog.defaultChatModel(for: provider)
        }
        return stored
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

    /// "bottom" or "top". / "bottom" або "top".
    @Published var indicatorPosition: String {
        didSet { defaults.set(indicatorPosition, forKey: "indicatorPosition") }
    }

    /// "classic", "glass" or "light".
    @Published var indicatorTheme: String {
        didSet { defaults.set(indicatorTheme, forKey: "indicatorTheme") }
    }

    /// "system" or a language code. Applied through AppleLanguages, so it takes
    /// effect after a relaunch; missing keys fall back to English.
    @Published var uiLanguage: String {
        didSet {
            defaults.set(uiLanguage, forKey: "uiLanguage")
            if uiLanguage == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([uiLanguage], forKey: "AppleLanguages")
            }
        }
    }

    /// "auto" keeps the spoken language; a code translates the transcript
    /// before it is inserted.
    @Published var outputLanguage: String {
        didSet { defaults.set(outputLanguage, forKey: "outputLanguage") }
    }

    /// When text is selected, the dictation edits it instead of inserting new
    /// text after it.
    @Published var selectionEditing: Bool {
        didSet { defaults.set(selectionEditing, forKey: "selectionEditing") }
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

    var activeEngineOrder: [String] { engineOrder.filter { isASREnabled(for: $0) } }

    var engineConfiguration: EngineConfiguration {
        EngineConfiguration(openAIBaseURL: openAIBaseURL, cloudTimeout: cloudTimeout,
                            asrModels: Dictionary(uniqueKeysWithValues: ProviderCatalog.all.map {
                                ($0.id, asrModel(for: $0.id))
                            }))
    }

    var languageOverride: String? {
        languageMode == "auto" ? nil : languageMode
    }

    var openAIChatBaseURL: String {
        cleanupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? openAIBaseURL : cleanupBaseURL
    }

    var isCleanupConfigured: Bool {
        guard cleanupEnabled, let spec = ProviderCatalog.spec(cleanupProvider) else { return false }
        return ProviderCatalog.isConfigured(spec) && !chatModel(for: cleanupProvider).isEmpty
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
        let legacyChatURL = defaults.string(forKey: "cleanupBaseURL") ?? ""
        cleanupBaseURL = legacyChatURL == "https://api.groq.com/openai/v1" ? "" : legacyChatURL
        let storedTimeout = defaults.object(forKey: "cleanupTimeout") as? Double
        // 1.5 s was the default before the 120B model; it is too tight for it.
        cleanupTimeout = (storedTimeout == nil || storedTimeout == 1.5) ? 3.0 : (storedTimeout ?? 3.0)
        pasteAutomatically = defaults.object(forKey: "pasteAutomatically") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        soundStyle = defaults.string(forKey: "soundStyle") ?? "bundled"
        indicatorPosition = defaults.string(forKey: "indicatorPosition") ?? "bottom"
        indicatorTheme = defaults.string(forKey: "indicatorTheme") ?? "classic"
        uiLanguage = defaults.string(forKey: "uiLanguage") ?? "system"
        asrModels = defaults.dictionary(forKey: "asrModels") as? [String: String] ?? [:]
        asrEnabled = defaults.dictionary(forKey: "asrEnabled") as? [String: Bool] ?? [:]
        outputLanguage = defaults.string(forKey: "outputLanguage") ?? "auto"
        selectionEditing = defaults.object(forKey: "selectionEditing") as? Bool ?? true
        showHUD = defaults.object(forKey: "showHUD") as? Bool ?? true
        keepAudioDays = defaults.object(forKey: "keepAudioDays") as? Int ?? 7
        hotkeyMode = defaults.string(forKey: "hotkeyMode") ?? "hold"
        // The old default (Control-Option-Space) is migrated to the new one
        // (right Command); a combination the user picked is kept.
        let storedKey = defaults.object(forKey: "hotkeyKeyCode") as? Int
        let storedMods = defaults.object(forKey: "hotkeyModifiers") as? Int
        let wasOldDefault = storedKey == 49 && storedMods == 0x1800
        hotkeyKeyCode = wasOldDefault ? 54 : (storedKey ?? 54)
        hotkeyModifiers = wasOldDefault ? 0x0100 : (storedMods ?? 0x0100)
        hotkeyLabel = wasOldDefault ? "" : (defaults.string(forKey: "hotkeyLabel") ?? "")
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
        case openAI: return "Custom / OpenAI-compatible"
        case "openrouter": return "OpenRouter"
        case "cerebras": return "Cerebras"
        case "ollama": return "Ollama (local)"
        case "ollamaCloud": return "Ollama Cloud"
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
