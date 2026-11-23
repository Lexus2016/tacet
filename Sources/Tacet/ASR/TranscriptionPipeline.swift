import Foundation

struct EngineConfiguration: Sendable {
    let groqModel: String
    let openAIBaseURL: String
    let openAIModel: String
    let cloudTimeout: TimeInterval
}

/// Runs the configured engine chain for one clip.
///
/// Order matters: the first engine that returns a plausible transcript wins.
/// A failure in any engine is recorded and the next one is tried immediately;
/// the clip itself is never discarded here, that is the caller's job.
final class TranscriptionPipeline {
    private let parakeet = ParakeetRecognizer.shared

    func transcribe(_ clip: AudioClip,
                    settings: PipelineSettings,
                    engines: EngineConfiguration) async -> Result<PipelineResult, PipelineFailure> {
        var attempts: [Attempt] = []

        for engineID in settings.engineOrder {
            guard let recognizer = makeRecognizer(engineID, engines: engines) else {
                attempts.append(Attempt(engine: engineID, error: "Unknown engine", latency: 0))
                continue
            }

            if !recognizer.isConfigured() {
                attempts.append(Attempt(engine: engineID,
                                        error: recognizer.configurationIssue() ?? "Not configured",
                                        latency: 0))
                continue
            }

            let started = Date()
            do {
                let timeout = engineID == EngineID.parakeet ? 90 : settings.cloudTimeout
                var transcript = try await withTimeout(timeout) {
                    try await recognizer.transcribe(clip, language: settings.languageOverride)
                }

                guard Plausibility.isAcceptable(transcript.text, duration: clip.duration) else {
                    throw RecognitionError.noSpeech
                }

                if settings.languageOverride == nil,
                   settings.dualLanguageCheck,
                   let alternate = LanguagePolicy.alternate(for: transcript,
                                                           expected: settings.expectedLanguage) {
                    if let second = try? await withTimeout(timeout, operation: {
                        try await recognizer.transcribe(clip, language: alternate)
                    }), Plausibility.isAcceptable(second.text, duration: clip.duration) {
                        transcript = LanguagePolicy.pick(first: transcript,
                                                         second: second,
                                                         secondRequested: alternate)
                    }
                }

                attempts.append(Attempt(engine: engineID, error: nil, latency: Date().timeIntervalSince(started)))
                return .success(PipelineResult(transcript: transcript, attempts: attempts))
            } catch {
                attempts.append(Attempt(engine: engineID,
                                        error: Self.describe(error),
                                        latency: Date().timeIntervalSince(started)))
            }
        }

        return .failure(PipelineFailure(attempts: attempts))
    }

    // MARK: Engines

    private func makeRecognizer(_ id: String, engines: EngineConfiguration) -> SpeechRecognizer? {
        switch id {
        case EngineID.groq:
            guard let url = URL(string: "https://api.groq.com/openai/v1") else { return nil }
            return CloudRecognizer(configuration: .init(
                id: EngineID.groq,
                displayName: "Groq",
                baseURL: url,
                model: engines.groqModel,
                keychainAccount: KeychainAccount.groq,
                environmentKey: "GROQ_API_KEY",
                timeout: engines.cloudTimeout
            ))

        case EngineID.openAI:
            guard let url = URL(string: engines.openAIBaseURL) else { return nil }
            return CloudRecognizer(configuration: .init(
                id: EngineID.openAI,
                displayName: "OpenAI-compatible",
                baseURL: url,
                model: engines.openAIModel,
                keychainAccount: KeychainAccount.openAI,
                environmentKey: "OPENAI_API_KEY",
                timeout: engines.cloudTimeout
            ))

        case EngineID.parakeet:
            return parakeet

        default:
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let recognition = error as? RecognitionError {
            return recognition.errorDescription ?? "Failed"
        }
        return error.localizedDescription
    }
}
