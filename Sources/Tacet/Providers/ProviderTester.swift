import AVFoundation
import Foundation

/// Small connectivity probes. They tell the user whether a key, a base URL and
/// a model name actually work before a dictation depends on them.
enum ProviderTester {
    static func testChat(spec: ProviderSpec,
                         baseURL: String?,
                         model: String) async -> Result<String, Error> {
        let base = (baseURL ?? spec.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base)?.appendingPathComponent("chat/completions"),
              !model.isEmpty
        else {
            return .failure(ModelCatalog.Failure.noBaseURL)
        }

        let apiKey = ProviderCatalog.key(for: spec)
        if spec.requiresKey, apiKey == nil {
            return .failure(ModelCatalog.Failure.http(401, "No API key saved"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 8,
            "temperature": 0,
            "messages": [["role": "user", "content": "Reply with the single word OK."]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await SharedSession.cloud.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(ModelCatalog.Failure.http(0, "No response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(ModelCatalog.Failure.http(http.statusCode, message(from: data)))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                return .failure(ModelCatalog.Failure.empty)
            }
            return .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(error)
        }
    }

    static func testTranscription(spec: ProviderSpec, model: String) async -> Result<String, Error> {
        guard let url = URL(string: spec.baseURL)?.appendingPathComponent("audio/transcriptions"),
              !model.isEmpty
        else {
            return .failure(ModelCatalog.Failure.noBaseURL)
        }

        guard let key = ProviderCatalog.key(for: spec) else {
            return .failure(ModelCatalog.Failure.http(401, "No API key"))
        }

        let silence = SilenceWav.data(seconds: 0.6)
        let boundary = "tacet-test-\(UUID().uuidString)"

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"silence.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(silence)
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await SharedSession.cloud.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(ModelCatalog.Failure.http(0, "No response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(ModelCatalog.Failure.http(http.statusCode, message(from: data)))
            }
            return .success("Key, endpoint and model accepted.")
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
