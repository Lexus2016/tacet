import AVFoundation
import Foundation

/// Small connectivity probes. They tell the user whether a key, a base URL and
/// a model name actually work before a dictation depends on them.
enum ProviderTester {
    static func testChat(spec: ProviderSpec,
                         baseURL: String?,
                         model: String,
                         session: URLSession = SharedSession.cloud) async -> Result<String, Error> {
        guard let url = spec.endpoint("chat/completions", baseURL: baseURL) else {
            return .failure(ModelCatalog.Failure.noBaseURL)
        }
        guard !model.isEmpty else { return .failure(ModelCatalog.Failure.noModel) }

        let key = ProviderCatalog.key(for: spec)
        guard !spec.requiresKey || key != nil else {
            return .failure(ModelCatalog.Failure.http(401, String(localized: "No API key saved")))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = EngineID.isGateway(spec.id) ? ProviderCatalog.gatewayRequestTimeout : 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spec.setHeaders(on: &request, key: key)

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": EngineID.isGateway(spec.id) ? 256 : 8,
            "temperature": 0,
            "messages": [["role": "user", "content": "Reply with the single word OK."]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await ProviderHealth.data(
                for: request, provider: spec.id, model: model, capability: .chat, session: session
            )
            guard let http = response as? HTTPURLResponse else {
                return .failure(ModelCatalog.Failure.http(0, "No response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(ModelCatalog.Failure.http(http.statusCode, message(from: data)))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                return .failure(ModelCatalog.Failure.unexpectedResponse)
            }
            // Reasoning models can use the full token budget before producing text.
            // Моделі з міркуванням іноді вичерпують ліміт до появи тексту.
            return .success((message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(error)
        }
    }

    static func testTranscription(spec: ProviderSpec,
                                  baseURL: String?,
                                  model: String,
                                  session: URLSession = SharedSession.cloud) async -> Result<String, Error> {
        guard let url = spec.endpoint("audio/transcriptions", baseURL: baseURL) else {
            return .failure(ModelCatalog.Failure.noBaseURL)
        }
        guard !model.isEmpty else { return .failure(ModelCatalog.Failure.noModel) }

        let key = ProviderCatalog.key(for: spec)
        guard !spec.requiresKey || key != nil else {
            return .failure(ModelCatalog.Failure.http(401, String(localized: "No API key saved")))
        }

        let request = CloudRecognizer.makeRequest(
            spec: spec, endpoint: url, key: key, model: model, timeout: 30,
            audio: SilenceWav.data(seconds: 0.6), language: nil
        )

        do {
            let (data, response) = try await ProviderHealth.data(
                for: request, provider: spec.id, model: model, capability: .transcription, session: session
            )
            guard let http = response as? HTTPURLResponse else {
                return .failure(ModelCatalog.Failure.http(0, "No response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(ModelCatalog.Failure.http(http.statusCode, message(from: data)))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["text"] is String else { return .failure(ModelCatalog.Failure.unexpectedResponse) }
            return .success("")
        } catch {
            return .failure(error)
        }
    }

    private static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
    }
}

/// A tiny valid WAV used only for connectivity tests.
enum SilenceWav {
    static func data(seconds: Double) -> Data {
        let sampleRate = 16_000
        let frames = Int(Double(sampleRate) * seconds)
        let payloadSize = frames * 2

        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + payloadSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(payloadSize))
        data.append(Data(count: payloadSize))
        return data
    }
}
