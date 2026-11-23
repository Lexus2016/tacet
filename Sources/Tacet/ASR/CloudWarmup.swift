import Foundation

/// Establishes the TLS connection to the cloud engine before the first
/// dictation, so the user does not pay a handshake on the first press.
/// A models request is tiny and is the same host the transcription uses.
enum CloudWarmup {
    static func warm() {
        guard let key = Keychain.secret(KeychainAccount.groq, environment: "GROQ_API_KEY") else { return }
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        SharedSession.cloud.dataTask(with: request) { _, _, _ in }.resume()
    }
}
