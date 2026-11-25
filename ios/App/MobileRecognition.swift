import Foundation
import Speech

enum MobileDictationError: LocalizedError {
    case microphoneDenied, speechDenied, noInput, unsupportedLanguage, tooShort, unavailable
    case audioSharingDisabled(String), missingKey(String)
    case translationNeedsOnlineRecognition, translationNeedsTextModel
    case selectionNeedsTextModel, selectionEditFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return String(localized: "Allow microphone access in Settings.")
        case .speechDenied: return String(localized: "Allow speech recognition in Settings.")
        case .noInput: return String(localized: "The microphone is unavailable.")
        case .unsupportedLanguage: return String(localized: "This layout’s speech language is unavailable on this device. Choose an online recognition model.")
        case .audioSharingDisabled(let name): return String(localized: "Allow sending dictation audio to \(name) in Tacet.")
        case .missingKey(let name): return String(localized: "Save an API key for \(name) in Tacet.")
        case .tooShort: return String(localized: "No speech was recorded. Try a longer phrase.")
        case .unavailable: return String(localized: "The recognition service is unavailable.")
        case .translationNeedsOnlineRecognition: return String(localized: "Choose an online recognition model and allow audio sharing to detect the spoken language.")
        case .translationNeedsTextModel: return String(localized: "Save a key for a text model to translate dictation.")
        case .selectionNeedsTextModel: return String(localized: "Choose a text model in Tacet to edit selected text.")
        case .selectionEditFailed: return String(localized: "The voice command could not be applied. The selected text was kept.")
        }
    }
}

enum MobileRecognition: String, CaseIterable, Identifiable, Sendable {
    case apple, groq, groqLarge, openai, openrouter

    struct Result: Equatable, Sendable {
        let text: String
        var language: String? = nil
    }

    struct Model: Equatable, Sendable {
        let engine: MobileRecognition
        let id: String

        init(_ engine: MobileRecognition, modelID: String = "") {
            self.engine = engine
            let manual = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            id = engine == .openrouter && !manual.isEmpty ? manual : engine.defaultModelID
        }

        var name: String { engine == .openrouter ? "\(engine.name) · \(id)" : engine.name }
    }

    var id: String { rawValue }

    var cloudProvider: MobileCloudProvider? {
        switch self {
        case .apple: nil
        case .groq, .groqLarge: .groq
        case .openai: .openai
        case .openrouter: .openrouter
        }
    }

    var name: String {
        switch self {
        case .apple: return String(localized: "Apple · on this iPhone")
        case .groq: return "Groq · Whisper Large v3 Turbo"
        case .groqLarge: return "Groq · Whisper Large v3"
        case .openai: return "OpenAI · Whisper"
        case .openrouter: return "OpenRouter"
        }
    }

    var defaultModelID: String {
        if self == .groqLarge { return "whisper-large-v3" }
        guard let provider = cloudProvider else { return "" }
        return ProviderCatalog.defaultASRModel(for: provider.rawValue)
    }

    func prepare() async throws {
        switch self {
        case .apple:
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard authorization == .authorized else { throw MobileDictationError.speechDenied }
        default:
            guard let provider = cloudProvider else { throw MobileDictationError.unavailable }
            guard provider.allowsAudio else { throw MobileDictationError.audioSharingDisabled(provider.name) }
            guard provider.hasKey else { throw MobileDictationError.missingKey(provider.name) }
        }
    }

    func transcribe(_ clip: AudioClip, locale: String, languageHint: String?, modelID: String) async throws -> Result {
        switch self {
        case .apple:
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
                  recognizer.supportsOnDeviceRecognition else { throw MobileDictationError.unsupportedLanguage }
            let request = SFSpeechURLRecognitionRequest(url: clip.url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            let results = AsyncThrowingStream<String, Error> { continuation in
                let operation = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        continuation.yield(result.bestTranscription.formattedString)
                        continuation.finish()
                    } else if let error {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in operation.cancel() }
            }
            for try await text in results { return Result(text: text, language: LanguagePolicy.normalize(locale)) }
            throw RecognitionError.empty
        default:
            guard let provider = cloudProvider, provider.allowsAudio,
                  let spec = ProviderCatalog.spec(provider.rawValue),
                  let endpoint = spec.endpoint("audio/transcriptions") else { throw MobileDictationError.unavailable }
            let engine = CloudRecognizer(configuration: .init(
                id: spec.id, displayName: spec.name, baseURL: endpoint,
                model: modelID,
                spec: spec, timeout: 22
            ))
            let response = try await engine.transcribe(clip, language: languageHint)
            return Result(text: response.text, language: response.language)
        }
    }

    static func transcribe(primary: Model, fallback: Model?,
                           timeout: TimeInterval = DictationBridge.recognitionTimeout,
                           using recognize: @escaping @Sendable (Model) async throws -> Result) async throws -> Result {
        let models = [primary, fallback == primary ? nil : fallback].compactMap { $0 }
        var errors: [String] = []
        for model in models {
            try Task.checkCancellation()
            do {
                let result = try await withTimeout(timeout) {
                    try await recognize(model)
                }
                try Task.checkCancellation()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw RecognitionError.empty }
                guard Plausibility.hasSpeechText(text) else { throw RecognitionError.noSpeech }
                return Result(text: text, language: result.language)
            } catch {
                try Task.checkCancellation()
                errors.append("\(model.name): \(error.localizedDescription)")
            }
        }
        throw RecognitionError.failed(errors.joined(separator: "\n"))
    }
}

enum MobileCloudProvider: String, CaseIterable, Identifiable {
    case groq, openai, openrouter

    var id: String { rawValue }
    var name: String { ProviderCatalog.spec(rawValue)?.name ?? rawValue }
    var hasKey: Bool { Keychain.string(rawValue) != nil }
    var audioPreference: String { "ios.audioConsent.\(rawValue)" }
    var allowsAudio: Bool { UserDefaults.standard.bool(forKey: audioPreference) }

    func cleanup(model: String, fallback: Bool) -> CleanupConfiguration? {
        guard hasKey, let spec = ProviderCatalog.spec(rawValue) else { return nil }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanupConfiguration(provider: rawValue, baseURL: spec.baseURL,
                                    model: model.isEmpty ? defaultChatModel(fallback: fallback) : model,
                                    timeout: DictationBridge.correctionTimeout)
    }

    func defaultChatModel(fallback: Bool) -> String {
        if self == .groq, fallback { return "openai/gpt-oss-20b" }
        return ProviderCatalog.defaultChatModel(for: rawValue)
    }
}
