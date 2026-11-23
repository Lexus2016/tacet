import Foundation

struct ProviderSpec: Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let requiresKey: Bool
    let supportsTranscription: Bool
    let supportsChat: Bool
    let environmentKey: String?

    var keychainAccount: String { id }
}

/// Everything the app knows about an endpoint: where it lives, whether it needs
/// a key, and what it can do. Base URLs are editable in Settings for providers
/// that people self-host.
enum ProviderCatalog {
    static let all: [ProviderSpec] = [
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
                     requiresKey: true, supportsTranscription: false, supportsChat: true,
                     environmentKey: "OPENROUTER_API_KEY"),
        ProviderSpec(id: "cerebras", name: "Cerebras",
                     baseURL: "https://api.cerebras.ai/v1",
                     requiresKey: true, supportsTranscription: false, supportsChat: true,
                     environmentKey: "CEREBRAS_API_KEY"),
        ProviderSpec(id: "ollama", name: "Ollama (local)",
                     baseURL: "http://localhost:11434/v1",
                     requiresKey: false, supportsTranscription: false, supportsChat: true,
                     environmentKey: nil),
        ProviderSpec(id: "ollamaCloud", name: "Ollama Cloud",
                     baseURL: "https://ollama.com/v1",
                     requiresKey: true, supportsTranscription: false, supportsChat: true,
                     environmentKey: "OLLAMA_API_KEY"),
    ]

    static var chatProviders: [ProviderSpec] { all.filter(\.supportsChat) }
    static var transcriptionProviders: [ProviderSpec] { all.filter(\.supportsTranscription) }

    static func spec(_ id: String) -> ProviderSpec? {
        all.first { $0.id == id }
    }

    /// Sensible first model per provider. Wrong guesses are harmless: the model
    /// picker and the test button exist precisely because catalogues change.
    static func defaultChatModel(for id: String) -> String {
        switch id {
        case "groq": return "openai/gpt-oss-20b"
        case "openai": return "gpt-4o-mini"
        case "openrouter": return "openai/gpt-4o-mini"
        case "cerebras": return "llama3.1-8b"
        case "ollama": return "llama3.2"
        case "ollamaCloud": return "gpt-oss:120b"
        default: return ""
        }
    }

    static func key(for spec: ProviderSpec) -> String? {
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
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noBaseURL: return "Invalid base URL."
            case .http(let status, let message): return "HTTP \(status): \(message)"
            case .empty: return "The provider returned no models."
            }
        }
    }

    static func fetch(spec: ProviderSpec, baseURL: String?) async throws -> [String] {
        let base = (baseURL ?? spec.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base)?.appendingPathComponent("models") else {
            throw Failure.noBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let key = ProviderCatalog.key(for: spec) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

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
