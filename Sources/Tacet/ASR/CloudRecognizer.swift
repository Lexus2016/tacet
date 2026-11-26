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
        let spec: ProviderSpec
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
        ProviderCatalog.key(for: configuration.spec)
    }

    func isConfigured() -> Bool {
        (!configuration.spec.requiresKey || apiKey != nil) && !configuration.model.isEmpty
    }

    func configurationIssue() -> String? {
        if configuration.spec.requiresKey, apiKey == nil { return "No API key" }
        return configuration.model.isEmpty ? "No model selected" : nil
    }

    func transcribe(_ clip: AudioClip, language: String?) async throws -> Transcript {
        let key = apiKey
        if configuration.spec.requiresKey, key == nil { throw RecognitionError.missingKey(displayName) }

        let request = Self.makeRequest(
            spec: configuration.spec, endpoint: configuration.baseURL, key: key,
            model: configuration.model, timeout: configuration.timeout,
            audio: try Data(contentsOf: clip.url), language: language
        )

        let started = Date()
        let (data, response) = try await ProviderHealth.data(for: request, provider: id,
                model: configuration.model, capability: .transcription, session: session)
        let latency = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw RecognitionError.failed("No response from \(displayName).")
        }
        guard (200..<300).contains(http.statusCode) else {
            if EngineID.isGateway(id), let issue = Self.gatewayAudioError(status: http.statusCode, data: data) {
                throw issue
            }
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
            language: TextLanguage.consistent(LanguagePolicy.normalize(decoded.language), with: text)
                ?? TextLanguage.detect(text) ?? language,
            engine: id,
            score: Self.confidence(from: segments),
            latency: latency
        )
    }

    // MARK: Request

    static func makeRequest(spec: ProviderSpec, endpoint: URL, key: String?, model: String,
                            timeout: TimeInterval, audio: Data, language: String?) -> URLRequest {
        let boundary = "tacet-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        spec.setHeaders(on: &request, key: key)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n")

        field("model", model)
        let verbose = EngineID.isGateway(spec.id) || spec.id == "groq" || ["whisper-1", "openai/whisper-1", "openai/whisper-large-v3",
                                            "openai/whisper-large-v3-turbo"].contains(model)
        field("response_format", verbose ? "verbose_json" : "json")
        field("temperature", "0")
        if let language {
            field("language", language)
        }

        append("--\(boundary)--\r\n")
        request.httpBody = body
        return request
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
        struct Body: Decodable {
            let message: String?
            let code: String?
        }
        let error: Body?
        let message: String?
    }

    static func gatewayAudioError(status: Int, data: Data) -> RecognitionError? {
        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.code
        switch (status, code) {
        case (429, "daily_audio_quota"):
            return .gatewayAudioQuota(daily: true)
        case (429, "plan_quota"):
            return .gatewayAudioQuota(daily: false)
        case (429, _):
            return .failed(String(localized: "Tacet is busy. Try dictating again in a moment."))
        case (403, "plan_paused"):
            return .failed(String(localized: "Dictation is paused. Check your Tacet plan."))
        case (403, "account_blocked"):
            return .failed(String(localized: "This Tacet account is blocked. Contact Tacet support."))
        case (403, "device_limit"):
            return .failed(String(localized: "This device exceeds the plan device limit."))
        case (400, _), (413, _), (415, _), (422, _):
            return .failed(String(localized: "Tacet could not process this recording."))
        default:
            return nil
        }
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
