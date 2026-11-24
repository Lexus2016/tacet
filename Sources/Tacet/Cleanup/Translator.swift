import Foundation

struct TranslationOutcome: Sendable {
    let text: String
    let translated: Bool
}

/// Translates the finished transcript into the language the user wants to type
/// in. Runs after cleanup, uses the same chat provider, and never replaces good
/// text with a suspicious answer: any failure returns the original.
final class Translator {
    private let session: URLSession

    init(session: URLSession = SharedSession.cloud) {
        self.session = session
    }

    func translate(_ text: String,
                   to target: String,
                   configuration: CleanupConfiguration?,
                   fallback: CleanupConfiguration? = nil,
                   sourceLanguage: String? = nil,
                   correctRecognition: Bool = false) async -> TranslationOutcome {
        let original = TranslationOutcome(text: text, translated: false)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, target != "auto" else { return original }

        // Already in the target language: no request needed.
        let source = TextLanguage.source(in: trimmed, reported: sourceLanguage)
        if source == target {
            return original
        }

        let backup = fallback.flatMap { $0.matches(configuration) ? nil : $0 }
        for model in [configuration, backup].compactMap({ $0 }) {
            guard !Task.isCancelled else { break }
            if let answer = await attempt(trimmed, to: target, sourceLanguage: source,
                                          configuration: model, correctRecognition: correctRecognition) {
                return TranslationOutcome(text: answer, translated: true)
            }
        }
        return original
    }

    private func attempt(_ trimmed: String, to target: String, sourceLanguage: String?, configuration: CleanupConfiguration,
                         correctRecognition: Bool) async -> String? {
        guard let endpoint = configuration.target else { return nil }
        let spec = endpoint.spec
        let key = ProviderCatalog.key(for: spec)
        if spec.requiresKey, key == nil { return nil }

        var request = URLRequest(url: endpoint.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(4, configuration.timeout + 2)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spec.setHeaders(on: &request, key: key)

        let payload: [String: Any] = [
            "model": endpoint.model,
            "temperature": 0,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(target: target, sourceLanguage: sourceLanguage,
                                                               correctRecognition: correctRecognition)],
                ["role": "user", "content": trimmed],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let preparedRequest = request
        guard let answer = try? await withTimeout(max(4, configuration.timeout + 2), operation: {
            try await Self.send(preparedRequest, provider: spec.id, model: endpoint.model, session: self.session)
        }), !Task.isCancelled else { return nil }

        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let ratio = Double(normalized.count) / Double(max(1, trimmed.count))
        guard ratio >= 0.35, ratio <= 2.2 else { return nil }

        // If the detector is confident the answer is in another language, the
        // model ignored the instruction: keep the original.
        if let detected = TextLanguage.detect(normalized), detected != target {
            return nil
        }

        return normalized
    }

    private static func send(_ request: URLRequest, provider: String, model: String,
                             session: URLSession) async throws -> String {
        let (data, response) = try await ProviderHealth.data(
            for: request, provider: provider, model: model,
            capability: .chat, session: session
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecognitionError.failed("Translation request failed")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw RecognitionError.failed("Unexpected translation response")
        }
        return content
    }

    private static func systemPrompt(target: String, sourceLanguage: String?, correctRecognition: Bool) -> String {
        let source = sourceLanguage.map { "\nLikely source language: \(TextLanguage.name(of: $0))." } ?? ""
        let correction = correctRecognition
            ? "\nFix clear transcription mistakes using the closest existing word in context. Preserve unclear words exactly as written. Never invent words."
            : "\nPreserve any source word you cannot understand in context exactly as written."
        return """
        Translate the user's text into \(languageName(target)).
        Return ONLY the translation: no quotes, no explanations, no preamble.
        Keep the meaning, names, numbers, URLs, code and formatting exactly.
        If the text is already in \(languageName(target)), return it unchanged.
        """ + source + correction
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "uk": return "Ukrainian"
        case "ru": return "Russian"
        case "en": return "English"
        case "de": return "German"
        case "es": return "Spanish"
        case "fr": return "French"
        case "pl": return "Polish"
        case "tr": return "Turkish"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        default: return code
        }
    }
}
