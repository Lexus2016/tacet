import Foundation

/// Any OpenAI-compatible `/audio/transcriptions` endpoint. Groq is the default
/// because whisper-large-v3-turbo there is both fast and strong on Ukrainian,
/// Russian and English; the same code covers OpenAI and self-hosted servers.
final class CloudRecognizer: SpeechRecognizer {
    struct Configuration {
        let id: String
        let displayName: String
        let baseURL: URL
        let model: String
        let keychainAccount: String
        let environmentKey: String
        let timeout: TimeInterval
    }

    let id: String
    let displayName: String
    private let configuration: Configuration

    init(configuration: Configuration) {
        self.id = configuration.id
        self.displayName = configuration.displayName
        self.configuration = configuration
    }

    private var session: URLSession { SharedSession.cloud }

    private var apiKey: String? {
        Keychain.secret(configuration.keychainAccount, environment: configuration.environmentKey)
    }

    func isConfigured() -> Bool {
        apiKey != nil && !configuration.model.isEmpty
    }

    var notConfiguredReason: String {
        if apiKey == nil { return "No API key" }
        return "No model selected"
    }

    func transcribe(_ clip: AudioClip, language: String?) async throws -> Transcript {
        guard let apiKey else { throw RecognitionError.missingKey(displayName) }

        let boundary = "tacet-\(UUID().uuidString)"
        let body = try makeBody(boundary: boundary, clip: clip, language: language)
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let started = Date()
        let (data, response) = try await session.data(for: request)
        let latency = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw RecognitionError.failed("No response from \(displayName).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecognitionError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }

        let decoded: VerboseResponse
        do {
            decoded = try JSONDecoder().decode(VerboseResponse.self, from: data)
        } catch {
            throw RecognitionError.failed("Unexpected response from \(displayName).")
        }

        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RecognitionError.empty }

        let segments = decoded.segments ?? []
        if let worstSilence = segments.compactMap(\.no_speech_prob).max(), worstSilence > 0.9, text.count < 12 {
            throw RecognitionError.noSpeech
        }

        return Transcript(
            text: text,
            language: LanguagePolicy.normalize(decoded.language),
            engine: id,
            score: Self.confidence(from: segments),
            latency: latency
        )
    }

    // MARK: Request

    private func makeBody(boundary: String, clip: AudioClip, language: String?) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        let audio = try Data(contentsOf: clip.url)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n")

        field("model", configuration.model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if let language {
            field("language", language)
        }

        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: Response

    private struct VerboseResponse: Decodable {
        let text: String
        let language: String?
        let segments: [Segment]?

        struct Segment: Decodable {
            let avg_logprob: Double?
            let no_speech_prob: Double?
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String? }
        let error: Body?
        let message: String?
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            if let message = envelope.error?.message ?? envelope.message, !message.isEmpty {
                return message
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return String(raw.prefix(200))
    }

    /// Mean token log-probability mapped to 0...1. Comparable with the local
    /// engine's confidence, which is what the language picker needs.
    private static func confidence(from segments: [VerboseResponse.Segment]) -> Double {
        let values = segments.compactMap(\.avg_logprob)
        guard !values.isEmpty else { return 0.65 }
        let mean = values.reduce(0, +) / Double(values.count)
        return min(1, max(0, exp(mean)))
    }
}
