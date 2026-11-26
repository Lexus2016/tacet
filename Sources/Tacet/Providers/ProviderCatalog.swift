import Foundation

struct ProviderSpec: Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let requiresKey: Bool
    let supportsTranscription: Bool
    let supportsChat: Bool
    let environmentKey: String?

    var keychainAccount: String {
        guard id == EngineID.hostedGateway, ProviderCatalog.usesPilotGateway else { return id }
        #if os(macOS)
        return "tacetGatewayPilotDevice"
        #else
        return "tacetGatewayPilot"
        #endif
    }

    func endpoint(_ path: String, baseURL override: String? = nil) -> URL? {
        Self.validBaseURL(override ?? baseURL)?.appendingPathComponent(path)
    }

    static func validBaseURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return nil }
        return parts.url
    }

    func setHeaders(on request: inout URLRequest, key: String?) {
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        #if os(macOS)
        // Practice requests of the first-run tour are not charged to the plan (capped by the gateway).
        // Тренувальні запити знайомства не списуються з тарифу (шлюз обмежує їх обсяг).
        if EngineID.isGateway(id), Onboarding.isRunning { request.setValue("1", forHTTPHeaderField: "X-Tacet-Onboarding") }
        #endif
        if id == "openrouter" {
            request.setValue("https://github.com/Lexus2016/tacet", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Tacet", forHTTPHeaderField: "X-Title")
        }
    }
}

/// Everything the app knows about an endpoint: where it lives, whether it needs
/// a key, and what it can do. Base URLs are editable in Settings for providers
/// that people self-host.
enum ProviderCatalog {
    static let usesPilotGateway = Bundle.main.object(forInfoDictionaryKey: "TacetPilotGateway") as? String == "YES"
    static let gatewayRequestTimeout: TimeInterval = 23
    static var all: [ProviderSpec] { builtin + customs }

    private static var customs: [ProviderSpec] {
        CustomProviderStore.shared.providers.map {
            ProviderSpec(id: $0.id,
                         name: $0.name,
                         baseURL: $0.baseURL,
                         requiresKey: $0.requiresKey,
                         supportsTranscription: true,
                         supportsChat: true,
                         environmentKey: nil)
        }
    }

    private static let builtin: [ProviderSpec] = [
        ProviderSpec(id: EngineID.hostedGateway, name: EngineID.displayName(EngineID.hostedGateway),
                     baseURL: usesPilotGateway ? "https://tacetapi.murable.ai/pilot/v1" : "https://tacetapi.murable.ai/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: usesPilotGateway ? "TACET_GATEWAY_PILOT_CLIENT_TOKEN" : "TACET_GATEWAY_HOSTED_CLIENT_TOKEN"),
        ProviderSpec(id: EngineID.gateway, name: EngineID.displayName(EngineID.gateway),
                     baseURL: "http://127.0.0.1:8787/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: "TACET_GATEWAY_CLIENT_TOKEN"),
        ProviderSpec(id: "groq", name: "Groq",
                     baseURL: "https://api.groq.com/openai/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: "GROQ_API_KEY"),
        ProviderSpec(id: "openai", name: "OpenAI",
                     baseURL: "https://api.openai.com/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: "OPENAI_API_KEY"),
        ProviderSpec(id: "openrouter", name: "OpenRouter",
                     baseURL: "https://openrouter.ai/api/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: "OPENROUTER_API_KEY"),
        ProviderSpec(id: "cerebras", name: "Cerebras",
                     baseURL: "https://api.cerebras.ai/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: "CEREBRAS_API_KEY"),
        ProviderSpec(id: "ollama", name: "Ollama (local)",
                     baseURL: "http://localhost:11434/v1",
                     requiresKey: false, supportsTranscription: true, supportsChat: true,
                     environmentKey: nil),
        ProviderSpec(id: "ollamaCloud", name: "Ollama Cloud",
                     baseURL: "https://ollama.com/v1",
                     requiresKey: true, supportsTranscription: true, supportsChat: true,
                     environmentKey: "OLLAMA_API_KEY"),
    ]

    static var chatProviders: [ProviderSpec] { all.filter(\.supportsChat) }
    static var transcriptionProviders: [ProviderSpec] { all.filter(\.supportsTranscription) }

    static func spec(_ id: String) -> ProviderSpec? {
        all.first { $0.id == id }
    }

    /// Sensible first model per provider. Wrong guesses are harmless: the model
    /// picker and the test button exist precisely because catalogues change.
    static func defaultASRModel(for id: String) -> String {
        switch id {
        case EngineID.gateway, EngineID.hostedGateway: return "tacet-transcription"
        case "groq": return "whisper-large-v3-turbo"
        case "openrouter": return "openai/whisper-large-v3"
        default: return "whisper-1"
        }
    }

    static func defaultChatModel(for id: String) -> String {
        switch id {
        case EngineID.gateway, EngineID.hostedGateway: return "tacet-text"
        case "groq": return "openai/gpt-oss-120b"
        case "openai": return "gpt-4o-mini"
        case "openrouter": return "openai/gpt-4o-mini"
        case "cerebras": return "llama3.1-8b"
        case "ollama": return "llama3.2"
        case "ollamaCloud": return "gpt-oss:120b"
        default: return ""
        }
    }

    static func key(for spec: ProviderSpec) -> String? {
        if spec.id == EngineID.hostedGateway, let token = EmailAccountClient.storedToken(for: spec) { return token }
        #if os(iOS)
        if spec.id == EngineID.hostedGateway { return Keychain.string(spec.keychainAccount) }
        #endif
        if let environment = spec.environmentKey {
            return Keychain.secret(spec.keychainAccount, environment: environment)
        }
        return Keychain.string(spec.keychainAccount)
    }

    static func isConfigured(_ spec: ProviderSpec) -> Bool {
        spec.requiresKey ? key(for: spec) != nil : true
    }
}

enum ModelCatalog {
    enum Failure: LocalizedError {
        case noBaseURL
        case noModel
        case unexpectedResponse
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noBaseURL: return String(localized: "Invalid base URL.")
            case .noModel: return String(localized: "Choose a model first.")
            case .unexpectedResponse: return String(localized: "The provider returned an unexpected response.")
            case .http(let status, let message): return "HTTP \(status): \(message)"
            case .empty: return "The provider returned no models."
            }
        }
    }

    static func fetch(spec: ProviderSpec, baseURL: String?, transcription: Bool = false) async throws -> [String] {
        guard let url = spec.endpoint("models", baseURL: baseURL) else {
            throw Failure.noBaseURL
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if spec.id == "openrouter" {
            components?.queryItems = [.init(name: "output_modalities", value: transcription ? "transcription" : "text")]
        }
        var request = URLRequest(url: components?.url ?? url)
        request.timeoutInterval = 15
        spec.setHeaders(on: &request, key: ProviderCatalog.key(for: spec))

        let (data, response) = try await SharedSession.cloud.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.http(0, "No response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8)?.prefix(160).description ?? "")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.empty
        }

        // OpenAI-compatible: {"data":[{"id":"..."}]}. Ollama native: {"models":[...]}.
        var ids: [String] = []
        if let dataArray = object["data"] as? [[String: Any]] {
            ids = dataArray.compactMap { $0["id"] as? String }
        } else if let models = object["models"] as? [[String: Any]] {
            ids = models.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        }

        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { throw Failure.empty }
        return unique
    }
}
