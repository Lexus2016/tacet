import Foundation

struct EngineConfiguration: Sendable {
    let openAIBaseURL: String
    let cloudTimeout: TimeInterval
    let asrModels: [String: String]
}

/// Runs the configured engine chain for one clip.
///
/// Order matters: the first engine that returns a plausible transcript wins.
/// A failure in any engine is recorded and the next one is tried immediately;
/// the clip itself is never discarded here, that is the caller's job.
final class TranscriptionPipeline {
    private let parakeet = ParakeetRecognizer.shared
    private let cloud: CloudAvailability

    init(cloud: CloudAvailability = .shared) {
        self.cloud = cloud
    }

    func transcribe(_ clip: AudioClip,
                    settings: PipelineSettings,
                    engines: EngineConfiguration) async -> Result<PipelineResult, PipelineFailure> {
        // The gateway accepts 8 MiB, so split its 16 kHz mono WAVs earlier.
        // Шлюз приймає 8 МіБ, тому ділимо WAV 16 кГц на коротші частини.
        let usesGateway = settings.engineOrder.contains(where: EngineID.isGateway)
        let chunkDuration: TimeInterval = usesGateway ? 240 : 480
        if clip.duration > (usesGateway ? chunkDuration : 600) {
            return await transcribeChunked(clip, seconds: chunkDuration, settings: settings, engines: engines)
        }
        return await transcribeSingle(clip, settings: settings, engines: engines)
    }

    private func transcribeSingle(_ clip: AudioClip,
                                  settings: PipelineSettings,
                                  engines: EngineConfiguration) async -> Result<PipelineResult, PipelineFailure> {
        var attempts: [Attempt] = []

        // Start the voice-based language check alongside the first engine: it
        // runs on the audio, so it catches Ukrainian speech decoded as Russian
        // text, which no post-hoc text check can see.
        let voiceCheck = startVoiceLanguageCheck(clip: clip, settings: settings)

        defer { voiceCheck?.cancel() }
        // The on-device model covers European languages only; a forced language it cannot
        // transcribe keeps the dictation cloud-only.
        // Модель на пристрої покриває лише європейські мови; примусова мова, якої вона не
        // розпізнає, лишає диктування суто хмарним.
        let localReady = settings.engineOrder.contains(EngineID.parakeet) && parakeet.isConfigured()
            && settings.languageOverride.map(ParakeetRecognizer.supports) != false
        for engineID in settings.engineOrder {
            if Task.isCancelled { break }
            if engineID == EngineID.parakeet, !localReady {
                attempts.append(Attempt(engine: engineID, error: parakeet.configurationIssue() ?? "Language not supported",
                                        latency: 0))
                continue
            }
            guard let recognizer = makeRecognizer(engineID, engines: engines) else {
                attempts.append(Attempt(engine: engineID, error: "Unknown engine", latency: 0))
                // A misconfigured gateway is a fault, not a reason to dictate on the device.
                // Неправильно налаштований шлюз — це збій, а не привід диктувати на пристрої.
                if EngineID.isGateway(engineID) { break }
                continue
            }

            if !recognizer.isConfigured() {
                attempts.append(Attempt(engine: engineID,
                                        error: recognizer.configurationIssue() ?? "Not configured",
                                        latency: 0))
                // Without a connected account there is no on-device dictation either.
                // Без підключеного акаунта диктування на пристрої теж немає.
                if EngineID.isGateway(engineID) { break }
                continue
            }

            // Checked only after the account is known to be connected: with no network path and
            // the on-device model ready, do not wait for a timeout.
            // Перевіряємо лише після того, як акаунт точно підключений: без мережевого шляху й з
            // готовою моделлю на пристрої не чекаємо на тайм-аут.
            if localReady, EngineID.isGateway(engineID), let reason = cloud.blocked() {
                attempts.append(Attempt(engine: engineID, error: reason.announcement, latency: 0,
                                        unreachable: true))
                continue
            }

            let started = Date()
            do {
                let timeout = engineTimeout(engineID, cloudTimeout: settings.cloudTimeout)
                var transcript = try await withTimeout(timeout) {
                    try await recognizer.transcribe(clip, language: settings.languageOverride)
                }

                guard Plausibility.isAcceptable(transcript.text) else {
                    throw RecognitionError.noSpeech
                }

                let voice = await voiceCheck?.value
                if let voice,
                   let language = voice.language,
                   voice.confidence >= 0.7,
                   language != LanguagePolicy.normalize(transcript.language) {
                    // The detector heard a different language than the engine
                    // reported: decode again with the detected one and keep the
                    // better result.
                    if let second = try? await withTimeout(timeout, operation: {
                        try await recognizer.transcribe(clip, language: language)
                    }), Plausibility.isAcceptable(second.text) {
                        transcript = LanguagePolicy.pick(first: transcript,
                                                         second: second,
                                                         secondRequested: language)
                    }
                } else if settings.languageOverride == nil,
                          settings.dualLanguageCheck,
                          let alternate = LanguagePolicy.alternate(for: transcript,
                                                                  expected: settings.expectedLanguage) {
                    if let second = try? await withTimeout(timeout, operation: {
                        try await recognizer.transcribe(clip, language: alternate)
                    }), Plausibility.isAcceptable(second.text) {
                        transcript = LanguagePolicy.pick(first: transcript,
                                                         second: second,
                                                         secondRequested: alternate)
                    }
                }

                attempts.append(Attempt(engine: engineID, error: nil, latency: Date().timeIntervalSince(started)))
                return .success(PipelineResult(transcript: transcript, attempts: attempts))
            } catch {
                let reason = LocalFallback.reason(for: error)
                attempts.append(Attempt(engine: engineID,
                                        error: Self.describe(error),
                                        latency: Date().timeIntervalSince(started),
                                        audioQuotaExhausted: reason == .quota, unreachable: reason == .unreachable))
                // Any other answer from the cloud is final: the on-device model covers an
                // exhausted allowance or an unreachable service, nothing else.
                // Будь-яка інша відповідь хмари остаточна: модель на пристрої покриває лише
                // вичерпаний ліміт або недосяжний сервіс.
                if EngineID.isGateway(engineID), reason == nil { break }
            }
        }

        return .failure(PipelineFailure(attempts: attempts))
    }

    // MARK: Long audio

    private func transcribeChunked(_ clip: AudioClip,
                                   seconds: TimeInterval,
                                   settings: PipelineSettings,
                                   engines: EngineConfiguration) async -> Result<PipelineResult, PipelineFailure> {
        let chunks = clip.chunked(seconds: seconds)
        var texts: [String] = []
        var usedEngines: Set<String> = []
        var first: Transcript?
        var attempts: [Attempt] = []
        var failures = 0

        defer {
            for chunk in chunks where chunk.url != clip.url {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        guard chunks.count > 1, chunks.allSatisfy({ $0.duration <= seconds }) else {
            let message = String(localized: "Could not split the recording. The original audio was kept.")
            return .failure(PipelineFailure(attempts: [Attempt(engine: "audio", error: message, latency: 0)]))
        }
        for chunk in chunks {
            if Task.isCancelled { return .failure(PipelineFailure(attempts: attempts)) }
            let result = await transcribeSingle(chunk, settings: settings, engines: engines)
            switch result {
            case .success(let output):
                texts.append(output.transcript.text)
                usedEngines.insert(output.transcript.engine)
                if first == nil { first = output.transcript }
                attempts.append(contentsOf: output.attempts)
            case .failure(let failure):
                attempts.append(contentsOf: failure.attempts)
                failures += 1
            }
        }

        guard let first, !texts.isEmpty else {
            return .failure(PipelineFailure(attempts: attempts))
        }

        // Chinese and Japanese do not separate words with spaces.
        let separator = (first.language == "zh" || first.language == "ja") ? "" : " "
        let joined = texts.joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // One part from the device makes the whole text on-device text: it must not be sent on
        // to the cloud for correction or translation as if the cloud had produced it.
        // Одна частина з пристрою робить увесь текст локальним: його не можна надсилати в хмару
        // на виправлення чи переклад так, ніби його створила хмара.
        let transcript = Transcript(text: joined,
                                    language: first.language,
                                    engine: usedEngines.contains(EngineID.parakeet) ? EngineID.parakeet : first.engine,
                                    score: first.score,
                                    latency: first.latency)
        return .success(PipelineResult(transcript: transcript,
                                       attempts: attempts,
                                       partial: failures > 0,
                                       totalParts: chunks.count,
                                       failedParts: failures))
    }

    // MARK: Engines

    private func startVoiceLanguageCheck(clip: AudioClip,
                                         settings: PipelineSettings) -> Task<LanguageDecision?, Never>? {
        guard settings.voiceLanguageCheck, settings.languageOverride == nil,
              settings.engineOrder.first.map(EngineID.isGateway) != true else { return nil }

        let detector = VoiceLanguageDetector(configuration: .init(
            model: settings.voiceLanguageModel,
            timeout: 2.5,
            candidates: settings.voiceLanguageCandidates
        ))
        guard detector.isConfigured() else { return nil }

        return Task { await detector.detect(clip) }
    }

    private func makeRecognizer(_ id: String, engines: EngineConfiguration) -> SpeechRecognizer? {
        if id == EngineID.parakeet { return parakeet }
        guard let spec = ProviderCatalog.spec(id), spec.supportsTranscription,
              let endpoint = spec.endpoint("audio/transcriptions", baseURL: id == EngineID.openAI ? engines.openAIBaseURL : nil)
        else { return nil }

        let model = engines.asrModels[id] ?? ProviderCatalog.defaultASRModel(for: id)
        return CloudRecognizer(configuration: .init(
            id: id, displayName: spec.name, baseURL: endpoint, model: model,
            spec: spec, timeout: engineTimeout(id, cloudTimeout: engines.cloudTimeout)
        ))
    }

    private func engineTimeout(_ id: String, cloudTimeout: TimeInterval) -> TimeInterval {
        switch id {
        case EngineID.parakeet: return 90
        case EngineID.gateway, EngineID.hostedGateway: return ProviderCatalog.gatewayRequestTimeout
        default: return cloudTimeout
        }
    }

    private static func describe(_ error: Error) -> String {
        if let recognition = error as? RecognitionError {
            return recognition.errorDescription ?? "Failed"
        }
        return error.localizedDescription
    }
}
