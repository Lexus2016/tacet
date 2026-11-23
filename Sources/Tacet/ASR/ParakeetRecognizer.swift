import FluidAudio
import Foundation

/// Offline fallback. Parakeet TDT v3 covers 25 European languages including
/// Ukrainian, Russian and English, runs on the Neural Engine and needs no key
/// and no network.
///
/// The model is never downloaded behind the user's back during a dictation:
/// `isConfigured` is false until the model exists on disk, and Settings offers
/// an explicit download.
actor ParakeetRecognizer: SpeechRecognizer {
    static let shared = ParakeetRecognizer()

    nonisolated let id = EngineID.parakeet
    nonisolated let displayName = "Parakeet (local)"

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    nonisolated var modelDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    nonisolated func isConfigured() -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: .v3)
    }

    nonisolated func configurationIssue() -> String? {
        isConfigured() ? nil : "Model not downloaded"
    }

    /// Loads the model into memory without downloading. Called by the pipeline
    /// on the first dictation and by Settings after a download.
    func warmUp() async throws {
        if manager != nil { return }
        if let loadTask {
            manager = try await loadTask.value
            return
        }

        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadTask = task

        do {
            manager = try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw RecognitionError.failed("Parakeet could not load: \(error.localizedDescription)")
        }
    }

    /// Explicit download from Settings. Returns the size on disk once ready.
    func downloadIfNeeded() async throws {
        if isConfigured() {
            try await warmUp()
            return
        }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.loadTask = nil
    }

    func transcribe(_ clip: AudioClip, language: String?) async throws -> Transcript {
        try await warmUp()
        guard let manager else {
            throw RecognitionError.failed("Parakeet is not loaded.")
        }

        let started = Date()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(clip.samples, decoderState: &decoderState, language: hint)
        let latency = Date().timeIntervalSince(started)

        let text = Self.clean(result.text)
        guard !text.isEmpty else { throw RecognitionError.empty }

        return Transcript(
            text: text,
            language: language ?? LanguagePolicy.cyrillicVerdict(text) ?? TextLanguage.detect(text),
            engine: id,
            score: min(1, max(0, Double(result.confidence))),
            latency: latency
        )
    }

    /// Parakeet's vocabulary has no token for a few characters and emits
    /// `<unk>` instead. Dropping the marker is less damaging than pasting it.
    private static func clean(_ raw: String) -> String {
        var text = raw
        if text.contains("<unk>") {
            text = text.replacingOccurrences(of: "<unk>", with: " ")
        }
        text = text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " +([,.;:!?…)])", with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
