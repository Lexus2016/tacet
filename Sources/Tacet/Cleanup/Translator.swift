import Foundation

struct TranslationOutcome: Sendable {
    let text: String
    let translated: Bool
}

/// Translates the finished transcript into the language the user wants to type
/// in. Runs after cleanup, uses the same chat provider, and never replaces good
/// text with a suspicious answer: any failure returns the original.
final class Translator {
    private var session: URLSession { SharedSession.cloud }

    func translate(_ text: String,
                   to target: String,
                   configuration: CleanupConfiguration) async -> TranslationOutcome {
        let original = TranslationOutcome(text: text, translated: false)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, target != "auto" else { return original }

        // Already in the target language: no request needed.
        if let detected = TextLanguage.detect(trimmed), detected == target {
            return original
        }

        guard let spec = ProviderCatalog.spec(configuration.provider) else { return original }
        let key = ProviderCatalog.key(for: spec)
        if spec.requiresKey, key == nil { return original }

        let base = configuration.provider == "openai" ? configuration.baseURL : spec.baseURL
        guard let url = spec.endpoint("chat/completions", baseURL: base) else {
            return original
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(4, configuration.timeout + 2)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spec.setHeaders(on: &request, key: key)

        let payload: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(target: target)],
                ["role": "user", "content": trimmed],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let preparedRequest = request
        guard let answer = try? await withTimeout(max(4, configuration.timeout + 2), operation: {
            try await Self.send(preparedRequest, configuration: configuration, session: self.session)
        }) else { return original }

        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return original }

        let ratio = Double(normalized.count) / Double(max(1, trimmed.count))
        guard ratio >= 0.35, ratio <= 2.2 else { return original }

        // If the detector is confident the answer is in another language, the
        // model ignored the instruction: keep the original.
        if let detected = TextLanguage.detect(normalized), detected != target {
            return original
        }

        return TranslationOutcome(text: normalized, translated: true)
    }

    private static func send(_ request: URLRequest, configuration: CleanupConfiguration,
                             session: URLSession) async throws -> String {
        let (data, response) = try await ProviderHealth.data(
            for: request, provider: configuration.provider, model: configuration.model,
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

    private static func systemPrompt(target: String) -> String {
        """
        Translate the user's text into \(languageName(target)).
        Return ONLY the translation: no quotes, no explanations, no preamble.
        Keep the meaning, names, numbers, URLs, code and formatting exactly.
        If the text is already in \(languageName(target)), return it unchanged.
        """
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
