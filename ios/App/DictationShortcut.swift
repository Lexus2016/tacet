import AppIntents

enum MobilePreferences {
    static let locale = "ios.speechLocale"
    static let defaultLocale = "en-US"
    static let translateToLayout = "ios.translateToLayout"
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
