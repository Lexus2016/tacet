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
    case gatewayAudioQuota(daily: Bool)
    case timedOut(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "\(what) is not configured."
        case .missingKey(let what): return "No API key for \(what)."
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .empty: return String(localized: "The engine returned no text.")
        case .noSpeech: return String(localized: "No speech was detected.")
        case .gatewayAudioQuota(let daily):
            return daily ? String(localized: "The daily dictation allowance has been used.")
                : String(localized: "The monthly dictation allowance has been used.")
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
    var audioQuotaExhausted = false
}

extension Array where Element == Attempt {
    /// Why the cloud did not serve this dictation, when a gateway attempt failed.
    /// Чому хмара не виконала це диктування, якщо спроба через шлюз не вдалася.
    var cloudFailure: LocalFallback? {
        if contains(where: \.audioQuotaExhausted) { return .quota }
        return contains { EngineID.isGateway($0.engine) && $0.error != nil } ? .unreachable : nil
    }
}

struct PipelineResult: Sendable {
    let transcript: Transcript
    let attempts: [Attempt]
    /// True when a long recording was split and at least one piece failed.
    var partial: Bool = false
    var totalParts: Int = 1
    var failedParts: Int = 0

    /// Set when the on-device model produced the text because the cloud could not.
    /// Задано, коли текст дала модель на пристрої, бо хмара не змогла.
    var localFallback: LocalFallback? {
        transcript.engine == EngineID.parakeet ? attempts.cloudFailure ?? .unreachable : nil
    }
}

struct PipelineFailure: Error, Sendable {
    let attempts: [Attempt]

    var audioQuotaExhausted: Bool { attempts.contains(where: \.audioQuotaExhausted) }

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
        "thanks for watching", "thanks for watching!",
        "thank you for watching", "thank you for watching.",
        "продолжение следует", "продолжение следует...", "спасибо за просмотр",
        "дякую за перегляд", "субтитры", "субтитры сделал dimatorzok",
    ]

    private static let annotations: Set<String> = [
        "[music]", "[applause]", "[silence]", "[inaudible]", "[noise]", "(music)", "(applause)",
    ]

    static func hasSpeechText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains { $0.isLetter || $0.isNumber } && !annotations.contains(trimmed.lowercased())
    }

    static func isAcceptable(_ text: String) -> Bool {
        hasSpeechText(text) && !hallucinations.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<T, Error>, tasks makeTasks: () -> [Task<Void, Never>]) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        tasks = makeTasks()
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        let tasks = tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = RaceBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            box.start(continuation) {
                let work = Task.detached {
                    do {
                        try Task.checkCancellation()
                        box.finish(.success(try await operation()))
                    } catch {
                        box.finish(.failure(error))
                    }
                }
                let timer = Task.detached {
                    do { try await Task.sleep(for: .seconds(max(0.05, seconds))) }
                    catch { return }
                    box.finish(.failure(RecognitionError.timedOut("the engine")))
                }
                return [work, timer]
            }
        }
    } onCancel: {
        box.finish(.failure(CancellationError()))
    }
}
