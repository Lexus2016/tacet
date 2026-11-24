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
}

/// The cleanup pass is a quality feature, not a dependency. Every path that
/// does not produce a clearly better text returns the raw transcript.
final class CleanupPipeline {
    private var session: URLSession { SharedSession.cloud }

    func clean(_ rawText: String, configuration: CleanupConfiguration?) async -> CleanupResult {
        guard let configuration,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .raw(rawText) }

        guard let spec = ProviderCatalog.spec(configuration.provider) else { return .raw(rawText) }
        let key = ProviderCatalog.key(for: spec)
        if spec.requiresKey, key == nil { return .raw(rawText) }

        let candidate = try? await withTimeout(configuration.timeout) {
            try await self.request(spec: spec, key: key, text: rawText, configuration: configuration)
        }
        guard let candidate else { return .raw(rawText) }
        let normalized = CleanupGuard.normalize(candidate)
        guard CleanupGuard.isAcceptable(input: rawText, output: normalized) else { return .raw(rawText) }
        return CleanupResult(text: normalized, engine: spec.id, changed: normalized != rawText)
    }

    // MARK: Request

    private func request(spec: ProviderSpec,
                         key: String?,
                         text: String,
                         configuration: CleanupConfiguration) async throws -> String {
        let base = spec.id == EngineID.openAI
            ? configuration.baseURL
            : spec.baseURL

        guard let url = spec.endpoint("chat/completions", baseURL: base) else {
            throw RecognitionError.failed("Invalid cleanup endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(configuration.timeout, 5)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spec.setHeaders(on: &request, key: key)

        let payload: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await ProviderHealth.data(for: request, provider: spec.id,
                model: configuration.model, capability: .chat, session: session)
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

        if text.hasPrefix("```"), text.hasSuffix("```") {
            var lines = text.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if !lines.isEmpty { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = text.components(separatedBy: .newlines)
        if lines.count > 1,
           let first = lines.first,
           first.count < 80,
           first.hasSuffix(":") || first.hasSuffix("：") {
            text = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

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

        if LanguagePolicy.isCyrillic(input), !LanguagePolicy.isCyrillic(trimmed) {
            return false
        }

        if input.count >= 25,
           let inputLanguage = TextLanguage.detect(input),
           let outputLanguage = TextLanguage.detect(trimmed),
           inputLanguage != outputLanguage {
            return false
        }

        return true
    }
}
