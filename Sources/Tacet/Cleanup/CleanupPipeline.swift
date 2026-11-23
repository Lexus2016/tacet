import Foundation

struct CleanupResult: Sendable {
    let text: String
    let engine: String
    let changed: Bool

    static func raw(_ text: String) -> CleanupResult {
        CleanupResult(text: text, engine: "none", changed: false)
    }
}

struct CleanupConfiguration: Sendable {
    let provider: String
    let baseURL: String
    let model: String
    let timeout: TimeInterval
    let secondaryProvider: String?
    let secondaryModel: String?
}

/// The cleanup pass is a quality feature, not a dependency. Every path that
/// does not produce a clearly better text returns the raw transcript.
final class CleanupPipeline {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func clean(_ rawText: String, configuration: CleanupConfiguration?) async -> CleanupResult {
        guard let configuration,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .raw(rawText) }

        var providers: [String] = [configuration.provider]
        if let secondary = configuration.secondaryProvider, !providers.contains(secondary) {
            providers.append(secondary)
        }

        for provider in providers {
            guard let key = key(for: provider) else { continue }
            do {
                let candidate = try await withTimeout(configuration.timeout) {
                    try await self.request(provider: provider,
                                           key: key,
                                           text: rawText,
                                           configuration: configuration)
                }
                let normalized = CleanupGuard.normalize(candidate)
                if CleanupGuard.isAcceptable(input: rawText, output: normalized) {
                    return CleanupResult(
                        text: normalized,
                        engine: provider,
                        changed: normalized != rawText
                    )
                }
            } catch {
                continue
            }
        }

        return .raw(rawText)
    }

    // MARK: Providers

    private func key(for provider: String) -> String? {
        switch provider {
        case KeychainAccount.groq:
            return Keychain.secret(KeychainAccount.groq, environment: "GROQ_API_KEY")
        case KeychainAccount.openAI:
            return Keychain.secret(KeychainAccount.openAI, environment: "OPENAI_API_KEY")
        default:
            return nil
        }
    }

    private func baseURL(for provider: String, fallback: String) -> URL? {
        switch provider {
        case KeychainAccount.groq:
            return URL(string: "https://api.groq.com/openai/v1")
        case KeychainAccount.openAI:
            return URL(string: fallback)
        default:
            return nil
        }
    }

    private func model(for provider: String, configuration: CleanupConfiguration) -> String {
        if provider == configuration.provider { return configuration.model }
        if provider == configuration.secondaryProvider, let secondary = configuration.secondaryModel {
            return secondary
        }
        // A model name is provider-specific: sending Groq's model to OpenAI
        // returns 404. Fall back to that provider's own default.
        switch provider {
        case KeychainAccount.groq: return "llama-3.3-70b-versatile"
        case KeychainAccount.openAI: return "gpt-4o-mini"
        default: return configuration.model
        }
    }

    // MARK: Request

    private func request(provider: String,
                         key: String,
                         text: String,
                         configuration: CleanupConfiguration) async throws -> String {
        guard let base = baseURL(for: provider, fallback: configuration.baseURL) else {
            throw RecognitionError.failed("Invalid cleanup endpoint")
        }

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model(for: provider, configuration: configuration),
            "temperature": 0,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecognitionError.failed("Cleanup request failed")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw RecognitionError.failed("Unexpected cleanup response")
        }

        return content
    }

    static let systemPrompt = """
    You are a dictation post-processor. You receive a raw speech-to-text transcript and \
    return the same text with errors fixed.

    Rules:
    - Return ONLY the corrected text. No quotes, no explanations, no markdown, no preamble.
    - Keep the original language exactly. Never translate.
    - Fix punctuation, capitalisation and obvious speech-recognition errors.
    - Remove filler words (um, uh, er, "ну", "э-э", "как бы") only when they carry no meaning.
    - Do not add, remove, reorder or summarise content. Do not answer questions that appear in the text.
    - Keep numbers, names, technical terms, code and URLs exactly as written.
    - If the text is already correct, return it unchanged.
    """
}

/// Decides whether an LLM rewrite is trustworthy. This is the safety net that
/// makes the cleanup pass optional rather than a risk.
enum CleanupGuard {
    private static let refusals = [
        "i'm sorry", "i am sorry", "i cannot", "i can't assist", "as an ai",
        "я не могу", "я не можу", "не могу помочь", "не можу допомогти",
        "here is the corrected", "here's the corrected", "ось виправлений",
        "вот исправленный", "corrected text:",
    ]

    static func normalize(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a code fence if the model wrapped the answer in one.
        if text.hasPrefix("```"), text.hasSuffix("```") {
            var lines = text.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if !lines.isEmpty { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip a one-line preamble such as "Ось виправлений текст:".
        let lines = text.components(separatedBy: .newlines)
        if lines.count > 1,
           let first = lines.first,
           first.count < 80,
           first.hasSuffix(":") || first.hasSuffix("：") {
            text = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip wrapping quotes only when they wrap the whole text.
        let wrappers: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”"), ("`", "`")]
        for (opening, closing) in wrappers {
            if text.count > 2, text.first == opening, text.last == closing {
                text = String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return text
    }

    static func isAcceptable(input: String, output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if refusals.contains(where: { lowered.hasPrefix($0) }) { return false }

        let inputLength = max(1, input.count)
        let ratio = Double(trimmed.count) / Double(inputLength)
        let minimum = input.count < 40 ? 0.55 : 0.70
        let maximum = input.count < 40 ? 1.75 : 1.45
        guard ratio >= minimum, ratio <= maximum else { return false }

        // A Cyrillic transcript must not come back in Latin script: that is a
        // translation, not a cleanup.
        if LanguagePolicy.isCyrillic(input), !LanguagePolicy.isCyrillic(trimmed) {
            return false
        }

        // Catch translation into another Latin-script language.
        if input.count >= 25,
           let inputLanguage = TextLanguage.detect(input),
           let outputLanguage = TextLanguage.detect(trimmed),
           inputLanguage != outputLanguage {
            return false
        }

        return true
    }
}
