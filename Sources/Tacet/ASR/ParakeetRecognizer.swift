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

    /// Whether the model can transcribe this ISO 639-1 language.
    /// Чи може модель розпізнати цю мову (код ISO 639-1).
    nonisolated static func supports(_ language: String) -> Bool {
        Language(rawValue: language) != nil
    }

    nonisolated func configurationIssue() -> String? {
        isConfigured() ? nil : "Model not downloaded"
    }

    /// Loads the model into memory. Only the explicit download from Settings may fetch it:
    /// a dictation loads strictly from disk and fails if the files are gone.
    /// Завантажує модель у пам'ять. Отримати її з мережі може лише явне завантаження з налаштувань:
    /// диктування читає суто з диска й завершується помилкою, якщо файлів немає.
    func warmUp(download: Bool = false) async throws {
        if manager != nil { return }
        if let loadTask {
            manager = try await loadTask.value
            return
        }

        let directory = modelDirectory
        let task = Task { () throws -> AsrManager in
            let models = download ? try await AsrModels.downloadAndLoad(version: .v3)
                : try AsrModels.loadLocal(from: directory, version: .v3)
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

    /// Frees the model after a quiet period. The next dictation reloads it from
    /// disk instead of keeping a gigabyte resident all day.
    func unload() {
        guard loadTask == nil else { return }
        manager = nil
    }

    /// Explicit download from Settings. Returns the size on disk once ready.
    func downloadIfNeeded() async throws {
        try await warmUp(download: true)
    }

    /// Frees the model and deletes its files inside the actor, so a dictation cannot be loading
    /// them at the same moment.
    /// Звільняє модель і вилучає її файли всередині актора, щоб диктування не могло завантажувати
    /// їх тієї ж миті.
    func removeModel() {
        loadTask?.cancel()
        loadTask = nil
        manager = nil
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    func transcribe(_ clip: AudioClip, language: String?) async throws -> Transcript {
        // Loading would fetch a missing model; a dictation must never start that download.
        // Завантаження в пам'ять підтягнуло б відсутню модель; диктування не має запускати це завантаження.
        guard isConfigured() else { throw RecognitionError.notConfigured(displayName) }
        try await warmUp(download: false)
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
