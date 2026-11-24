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

    var target: (spec: ProviderSpec, endpoint: URL, model: String)? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let spec = ProviderCatalog.spec(provider), spec.supportsChat,
              let endpoint = spec.endpoint("chat/completions",
                                           baseURL: spec.id == EngineID.openAI ? baseURL : nil)
        else { return nil }
        return (spec, endpoint, model)
    }

    var isConfigured: Bool {
        guard let target else { return false }
        return ProviderCatalog.isConfigured(target.spec)
    }

    func matches(_ other: CleanupConfiguration?) -> Bool {
        guard let target, let other = other?.target else { return false }
        return target.spec.id == other.spec.id && target.endpoint == other.endpoint && target.model == other.model
    }
}

/// The cleanup pass is a quality feature, not a dependency. Every path that
/// does not produce a clearly better text returns the raw transcript.
final class CleanupPipeline {
    private let session: URLSession

    init(session: URLSession = SharedSession.cloud) {
        self.session = session
    }

    func clean(_ rawText: String, sourceLanguage: String? = nil, configuration: CleanupConfiguration?,
               fallback: CleanupConfiguration? = nil) async -> CleanupResult {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .raw(rawText) }
        let source = TextLanguage.source(in: rawText, reported: sourceLanguage)
        let prompt = Self.systemPrompt(sourceLanguage: source)
        let backup = fallback.flatMap { $0.matches(configuration) ? nil : $0 }
        for attempt in [configuration, backup].compactMap({ $0 }) {
            guard !Task.isCancelled else { break }
            if let result = await attemptClean(rawText, prompt: prompt, configuration: attempt) { return result }
        }
        return .raw(rawText)
    }

    private func attemptClean(_ rawText: String, prompt: String, configuration: CleanupConfiguration) async -> CleanupResult? {
        guard let target = configuration.target else { return nil }
        let key = ProviderCatalog.key(for: target.spec)
        if target.spec.requiresKey, key == nil { return nil }
        let candidate = try? await withTimeout(configuration.timeout) {
            try await self.request(spec: target.spec, url: target.endpoint, key: key, text: rawText, prompt: prompt,
                                   model: target.model, timeout: configuration.timeout)
        }
        guard !Task.isCancelled, let candidate else { return nil }
        if candidate.trimmingCharacters(in: .whitespacesAndNewlines) == rawText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return CleanupResult(text: rawText, engine: target.spec.id, changed: false)
        }
        let normalized = CleanupGuard.normalize(candidate)
        guard CleanupGuard.isAcceptable(input: rawText, output: normalized) else { return nil }
        return CleanupResult(text: normalized, engine: target.spec.id, changed: normalized != rawText)
    }

    // MARK: Request

    private func request(spec: ProviderSpec,
                         url: URL,
                         key: String?,
                         text: String,
                         prompt: String,
                         model: String,
                         timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(timeout, 5)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spec.setHeaders(on: &request, key: key)

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await ProviderHealth.data(for: request, provider: spec.id,
                model: model, capability: .chat, session: session)
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

    static func systemPrompt(sourceLanguage: String?) -> String {
        let language = sourceLanguage.map { "Likely source language: \(TextLanguage.name(of: $0)). Use it as a spelling and grammar hint." }
            ?? "Use the transcript's wording to infer its language when clear."
        return """
        You are a dictation post-processor. You receive a raw speech-to-text transcript and \
        return the same text with errors fixed.

        \(language)

        Rules:
        - Return ONLY the corrected text. No quotes, no explanations, no markdown, no preamble.
        - Keep the original language of every passage, including mixed-language speech and quotations. Never translate.
        - Fix punctuation, capitalisation and obvious speech-recognition errors.
        - For a misrecognised word, use the closest existing word only when the sentence makes the intended word clear.
        - If a word remains unclear in context, return that word exactly as it appears in the original transcript. Never invent words.
        - If the intended meaning of the transcript is unclear overall, return the original transcript unchanged.
        - Remove filler words (um, uh, er, "ну", "э-э", "как бы") only when they carry no meaning.
        - Do not add, remove, reorder or summarise content. Do not answer questions that appear in the text.
        - Keep numbers, names, technical terms, code and URLs exactly as written.
        - If the text is already correct, return it unchanged.
        """
    }
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
