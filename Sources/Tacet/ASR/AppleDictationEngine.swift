import AVFoundation
import Foundation
import Speech

/// Tacet Solo for languages neither bundled model covers: the system's on-device dictation
/// (iOS and macOS 26 or later). The system downloads and keeps the language assets itself.
/// Tacet Solo для мов, яких не покриває жодна з вбудованих моделей: системне диктування на
/// пристрої (iOS і macOS 26 або новіші). Мовні ресурси система завантажує та зберігає сама.
enum AppleDictationEngine {
    /// ISO 639-1 codes served here, with the locale the system knows them by.
    /// Коди ISO 639-1, які обслуговуються тут, і локаль, під якою їх знає система.
    private static let locales = ["hi": "hi-IN"]
    static var languages: Set<String> {
        if #available(iOS 26.0, macOS 26.0, *) { return Set(locales.keys) }
        return []
    }

    private static func readyKey(_ language: String) -> String { "solo.appleDictation.\(language)" }

    /// True once the assets were installed by an explicit download. / True, щойно ресурси встановлено явним завантаженням.
    static func isReady(_ language: String) -> Bool {
        languages.contains(language) && UserDefaults.standard.bool(forKey: readyKey(language))
    }

    static func forget() {
        for language in locales.keys { UserDefaults.standard.removeObject(forKey: readyKey(language)) }
    }

    static func download(_ language: String) async throws {
        guard #available(iOS 26.0, macOS 26.0, *), let module = module(language) else {
            throw RecognitionError.notConfigured("Tacet Solo")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        UserDefaults.standard.set(true, forKey: readyKey(language))
    }

    static func transcribe(_ clip: AudioClip, language: String) async throws -> String {
        guard #available(iOS 26.0, macOS 26.0, *), isReady(language), let module = module(language) else {
            throw RecognitionError.notConfigured("Tacet Solo")
        }
        // A dictation never downloads: if the system dropped the assets, fail and ask for a new download.
        // Диктування нічого не завантажує: якщо система прибрала ресурси, завершуємо помилкою й просимо завантажити знову.
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            UserDefaults.standard.removeObject(forKey: readyKey(language))
            throw RecognitionError.notConfigured("Tacet Solo")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: clip.url)
        async let text = module.results.reduce(into: "") { $0 += String($1.text.characters) }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func module(_ language: String) -> DictationTranscriber? {
        guard let identifier = locales[language] else { return nil }
        return DictationTranscriber(locale: Locale(identifier: identifier), contentHints: [],
                                    transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])
    }
}
