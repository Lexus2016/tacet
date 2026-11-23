import Foundation

struct Transcript: Sendable {
    let text: String
    /// ISO 639-1 code reported by the engine, when it reports one.
    let language: String?
    let engine: String
    /// Normalised 0...1 confidence. Comparable across engines.
    let score: Double
    let latency: TimeInterval
}

enum RecognitionError: LocalizedError, Sendable {
    case notConfigured(String)
    case missingKey(String)
    case http(status: Int, message: String)
    case empty
    case noSpeech
    case timedOut(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "\(what) is not configured."
        case .missingKey(let what): return "No API key for \(what)."
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .empty: return "The engine returned no text."
        case .noSpeech: return "No speech was detected."
        case .timedOut(let engine): return "\(engine) timed out."
        case .cancelled: return "Cancelled."
        case .failed(let message): return message
        }
    }
}

protocol SpeechRecognizer: AnyObject {
    var id: String { get }
    var displayName: String { get }

    /// Cheap synchronous check: can this engine run right now without a
    /// download or a missing key?
    func isConfigured() -> Bool

    /// Human-readable reason when `isConfigured` is false.
    func configurationIssue() -> String?

    func transcribe(_ clip: AudioClip, language: String?) async throws -> Transcript
}

extension SpeechRecognizer {
    func configurationIssue() -> String? {
        isConfigured() ? nil : "Not configured"
    }
}

struct Attempt: Sendable {
    let engine: String
    let error: String?
    let latency: TimeInterval
}

struct PipelineResult: Sendable {
    let transcript: Transcript
    let attempts: [Attempt]
}

struct PipelineFailure: Error, Sendable {
    let attempts: [Attempt]

    var localizedDescription: String {
        let last = attempts.last { $0.error != nil }?.error
        return last ?? "No transcription engine is available."
    }
}

struct PipelineSettings: Sendable {
    let languageOverride: String?
    let engineOrder: [String]
    let dualLanguageCheck: Bool
    let cloudTimeout: TimeInterval
}

// MARK: - Plausibility

enum Plausibility {
    /// Whisper produces these when the audio is silence or noise. They are the
    /// single most common source of "empty dictation" bugs.
    private static let hallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!",
        "thank you for watching", "thank you for watching.", "you", "bye",
        "продолжение следует", "продолжение следует...", "спасибо за просмотр",
        "дякую за перегляд", "субтитры", "субтитры сделал dimatorzok",
        "[music]", "[applause]", "(music)", "♪", "...",
    ]

    static func isAcceptable(_ text: String, duration: TimeInterval) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let letters = trimmed.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return false }

        if hallucinations.contains(trimmed.lowercased()) { return false }

        // A two-second clip producing four characters is almost always a
        // hallucination, not a very short word.
        if duration > 1.8, Double(letters.count) < duration * 1.2 {
            return false
        }

        return true
    }
}

// MARK: - Timeout

func withTimeout<T>(_ seconds: TimeInterval,
                    operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
            throw RecognitionError.timedOut("the engine")
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw RecognitionError.timedOut("the engine")
        }
        group.cancelAll()
        return result
    }
}
