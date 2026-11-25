import Foundation

// The host app owns the credential and all network requests.
// Ключ і мережеві запити належать основному застосунку.
enum MobileGateway {
    private static var gateway: ProviderSpec? { ProviderCatalog.spec(EngineID.hostedGateway) }
    static var isProvisioned: Bool { gateway.flatMap(ProviderCatalog.key(for:)) != nil }

    static var textConfiguration: CleanupConfiguration {
        CleanupConfiguration(provider: EngineID.hostedGateway, baseURL: "",
                             model: ProviderCatalog.defaultChatModel(for: EngineID.hostedGateway),
                             timeout: ProviderCatalog.gatewayRequestTimeout)
    }

    static func validateAccessKey(_ enteredKey: String,
                                  send: (URLRequest) async throws -> (Data, URLResponse) = {
                                      try await SharedSession.cloud.data(for: $0)
                                  }) async throws -> String {
        guard let key = normalizedKey(enteredKey) else { throw AccessError.invalidKey }
        guard let gateway = ProviderCatalog.spec(EngineID.hostedGateway), let url = gateway.endpoint("models") else {
            throw MobileDictationError.unavailable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        gateway.setHeaders(on: &request, key: key)
        let (data, response) = try await send(request)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw AccessError.invalidKey }
        guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200,
              (try? JSONDecoder().decode(ModelList.self, from: data))?.object == "list" else {
            throw MobileDictationError.unavailable
        }
        return key
    }

    static func saveAccessKey(_ enteredKey: String) async throws {
        let key = try await validateAccessKey(enteredKey)
        try Task.checkCancellation()
        guard let gateway, Keychain.set(key, account: gateway.keychainAccount, deviceOnly: true) else { throw AccessError.storage }
    }

    private static func normalizedKey(_ value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (24...256).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return key
    }

    private struct ModelList: Decodable { let object: String }

    enum AccessError: LocalizedError {
        case invalidKey, storage

        var errorDescription: String? {
            switch self {
            case .invalidKey: String(localized: "This Tacet access key is invalid.")
            case .storage: String(localized: "The Tacet access key could not be saved.")
            }
        }
    }

    #if DEBUG
    static func provisionDevelopmentDevice() {
        guard let gateway, let variable = gateway.environmentKey,
              let value = ProcessInfo.processInfo.environment[variable],
              let key = normalizedKey(value) else { return }
        Keychain.set(key, account: gateway.keychainAccount, deviceOnly: true)
    }
    #endif
}

enum MobileDictationError: LocalizedError {
    case microphoneDenied, noInput, tooShort, unavailable
    case gatewayNotProvisioned, selectionEditFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return String(localized: "Allow microphone access in Settings.")
        case .noInput: return String(localized: "The microphone is unavailable.")
        case .tooShort: return String(localized: "No speech was recorded. Try a longer phrase.")
        case .unavailable: return String(localized: "The Tacet gateway is unavailable. Try again.")
        case .gatewayNotProvisioned: return String(localized: "This iPhone is not connected to Tacet Gateway yet.")
        case .selectionEditFailed: return String(localized: "The voice command could not be applied. The selected text was kept.")
        }
    }
}

enum MobileRecognition {
    struct Result: Equatable, Sendable {
        let text: String
        var language: String? = nil
    }

    static func transcribe(_ clip: AudioClip, languageHint: String?) async throws -> Result {
        guard MobileGateway.isProvisioned else { throw MobileDictationError.gatewayNotProvisioned }
        guard let spec = ProviderCatalog.spec(EngineID.hostedGateway),
              let url = spec.endpoint("audio/transcriptions") else { throw MobileDictationError.unavailable }
        let engine = CloudRecognizer(configuration: .init(
            id: spec.id, displayName: spec.name, baseURL: url,
            model: ProviderCatalog.defaultASRModel(for: spec.id), spec: spec,
            timeout: ProviderCatalog.gatewayRequestTimeout
        ))
        return try await validatedTranscription {
            do {
                let response = try await engine.transcribe(clip, language: languageHint)
                return Result(text: response.text, language: response.language)
            } catch RecognitionError.http(let status, _) where status == 401 {
                throw MobileDictationError.gatewayNotProvisioned
            } catch RecognitionError.http(let status, _) where status >= 500 {
                throw MobileDictationError.unavailable
            }
        }
    }

    static func validatedTranscription(timeout: TimeInterval = DictationBridge.recognitionTimeout,
                                        using recognize: @escaping @Sendable () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        let result = try await withTimeout(timeout, operation: recognize)
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RecognitionError.empty }
        guard Plausibility.hasSpeechText(text) else { throw RecognitionError.noSpeech }
        return Result(text: text, language: result.language)
    }
}
