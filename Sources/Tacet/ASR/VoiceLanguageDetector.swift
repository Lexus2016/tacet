import Foundation

struct LanguageDecision: Sendable {
    let language: String?
    let confidence: Double
}

/// Asks Google's Gemini Decision 1, through OpenRouter, which language is
/// actually spoken in the clip.
///
/// This is the only check in the app that listens to the voice rather than
/// reading the transcript: it catches the case where Ukrainian speech is
/// decoded into Russian words, which no text-based heuristic can detect.
///
/// The Decisions API is not OpenAI-compatible: it takes a `state` and typed
/// `questions`, and returns calibrated probabilities instead of text.
final class VoiceLanguageDetector {
    struct Configuration: Sendable {
        let model: String
        let timeout: TimeInterval
        let candidates: [String]
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    private var session: URLSession { SharedSession.cloud }

    func isConfigured() -> Bool {
        Keychain.secret(KeychainAccount.openRouter, environment: "OPENROUTER_API_KEY") != nil
    }

    /// Returns nil on any failure: the detector is an enhancement, never a
    /// dependency, and dictation must continue without it.
    func detect(_ clip: AudioClip) async -> LanguageDecision? {
        guard let key = Keychain.secret(KeychainAccount.openRouter, environment: "OPENROUTER_API_KEY"),
              !configuration.model.isEmpty,
              let audio = try? Data(contentsOf: clip.url)
        else { return nil }

        var request = URLRequest(url: ProviderHealth.voiceLanguageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/Lexus2016/tacet", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Tacet", forHTTPHeaderField: "X-Title")

        let criteria = Dictionary(uniqueKeysWithValues: configuration.candidates.map { ($0, Self.displayName($0)) })
        let payload: [String: Any] = [
            "model": configuration.model,
            "state": [
                "A dictation recording. Identify the language being spoken.",
                [
                    "type": "input_audio",
                    "input_audio": [
                        "data": audio.base64EncodedString(),
                        "format": "wav",
                    ],
                ],
            ],
            "questions": [
                "language": [
                    "type": "choice",
                    "instructions": "Which language is spoken in the audio? Ukrainian and Russian are close; answer with the language actually spoken, not the closest one. If the speech mixes languages, choose the dominant one.",
                    "criteria": criteria,
                ],
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        do {
            let (data, response) = try await ProviderHealth.data(for: request, provider: "openrouter",
                model: configuration.model, capability: .voiceLanguage, session: session)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let decoded = try? JSONDecoder().decode(DecisionResponse.self, from: data),
                  let answer = decoded.answers?["language"],
                  let choice = answer.choice
            else { return nil }

            let confidence = answer.probabilities?[choice] ?? 0
            return LanguageDecision(language: LanguagePolicy.normalize(choice), confidence: confidence)
        } catch {
            return nil
        }
    }

    private struct DecisionResponse: Decodable {
        struct Answer: Decodable {
            let type: String?
            let choice: String?
            let probabilities: [String: Double]?
        }
        let answers: [String: Answer]?
    }

    private static func displayName(_ code: String) -> String {
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
