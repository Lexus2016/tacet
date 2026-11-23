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
    /// Language last used in the current app, used to skip a redundant second
    /// decode. Never used to force a decode.
    var expectedLanguage: String? = nil
    /// Listen to the clip with a decision model instead of guessing from text.
    var voiceLanguageCheck: Bool = false
    var voiceLanguageModel: String = "google/gemini-decision-1"
    /// Languages the detector may choose from.
    var voiceLanguageCandidates: [String] = ["uk", "ru", "en"]
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
        // hallucination, not a very short word. 0.8 chars/s still lets "yes"
        // through in a three-second answer.
        if duration > 1.8, Double(letters.count) < duration * 0.8 {
            return false
        }

        return true
    }
}

// MARK: - Timeout

/// Runs the operation with a hard deadline. The work is detached, so a stalled
/// engine (a Core ML call that ignores cancellation, a hung socket) cannot keep
/// the dictation in the processing state: the caller gets a timeout and moves
/// to the next engine.
private final class RaceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let box = RaceBox(continuation)

        let work = Task.detached {
            do {
                box.resume(.success(try await operation()))
            } catch {
                box.resume(.failure(error))
            }
        }

        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
            work.cancel()
            box.resume(.failure(RecognitionError.timedOut("the engine")))
        }
    }
}
