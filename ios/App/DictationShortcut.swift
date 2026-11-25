import AppIntents

enum MobilePreferences {
    static let provider = "ios.recognizer"
    static let recognitionModel = "ios.recognitionModel"
    static let fallbackEnabled = "ios.recognitionFallbackEnabled"
    static let fallback = "ios.recognitionFallback"
    static let fallbackRecognitionModel = "ios.fallbackRecognitionModel"
    static let locale = "ios.speechLocale"
    static let defaultLocale = "en-US"
    static let cleanupEnabled = "ios.cleanupEnabled"
    static let selectionEditing = "ios.selectionEditing"
    static let translateToLayout = "ios.translateToLayout"
    static let cleanupProvider = "ios.cleanupProvider"
    static let cleanupModel = "ios.cleanupModel"
    static let cleanupFallbackEnabled = "ios.cleanupFallbackEnabled"
    static let cleanupFallbackProvider = "ios.cleanupFallbackProvider"
    static let cleanupFallbackModel = "ios.cleanupFallbackModel"

    static func migrateAudioConsent() {
        let preference = MobileCloudProvider.groq.audioPreference
        // Earlier builds only saved a Groq key after explicit audio consent.
        // Попередні збірки зберігали ключ Groq лише після явної згоди на надсилання аудіо.
        if UserDefaults.standard.object(forKey: preference) == nil {
            UserDefaults.standard.set(MobileCloudProvider.groq.hasKey, forKey: preference)
        }
    }
}

struct EnableTacetDictation: AppIntent {
    static let title: LocalizedStringResource = "Enable Tacet dictation"
    static let description = IntentDescription("Start a dictation session for the Tacet keyboard.")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await MobileDictationSession.shared.enableConfigured() else {
            return .result(dialog: "Open Tacet to see what needs attention.")
        }
        return .result(dialog: "Tacet is ready. Return to your text field.")
    }
}

struct TacetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnableTacetDictation(),
            phrases: ["Enable \(.applicationName) dictation", "Start \(.applicationName) dictation"],
            shortTitle: "Enable Tacet dictation",
            systemImageName: "mic.fill"
        )
    }
}
