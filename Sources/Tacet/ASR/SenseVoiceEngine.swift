import FluidAudio
import Foundation

/// The second Tacet Solo model: SenseVoiceSmall for Chinese, which Parakeet does not cover.
/// Model weights: FunASR Model Open Source License; converted to Core ML by FluidInference.
/// Друга модель Tacet Solo: SenseVoiceSmall для китайської, якої Parakeet не покриває.
/// Ваги моделі: FunASR Model Open Source License; конвертація в Core ML — FluidInference.
actor SenseVoiceEngine {
    static let shared = SenseVoiceEngine()

    /// Languages routed to this model. The model also covers Cantonese, Japanese and Korean;
    /// only Chinese has been verified on a device so far.
    /// Мови, які обслуговує ця модель. Вона покриває ще кантонську, японську й корейську;
    /// на пристрої поки перевірено лише китайську.
    static let languages: Set<String> = ["zh"]
    private static let precision = SenseVoiceEncoderPrecision.int8
    /// With inverse text normalisation: punctuation and digits. / Із нормалізацією: розділові знаки й цифри.
    private static let textNorm: Int32 = 14

    private var manager: SenseVoiceManager?

    nonisolated var modelDirectory: URL {
        ParakeetRecognizer.shared.modelDirectory.deletingLastPathComponent()
            .appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
    }

    nonisolated func isReady() -> Bool {
        SenseVoiceModels.modelsExist(at: modelDirectory, precision: Self.precision)
    }

    /// Explicit download only; a dictation never fetches the model.
    /// Лише явне завантаження; диктування модель не завантажує.
    func download() async throws {
        _ = try await SenseVoiceModels.download(precision: Self.precision)
    }

    func unload() { manager = nil }

    func remove() {
        manager = nil
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard isReady() else { throw RecognitionError.notConfigured("Tacet Solo") }
        if manager == nil {
            let models = try SenseVoiceModels.load(from: modelDirectory, precision: Self.precision)
            manager = SenseVoiceManager(models: models, textNorm: Self.textNorm)
        }
        guard let manager else { throw RecognitionError.failed("Tacet Solo is not loaded.") }
        return try await manager.transcribe(audio: samples)
    }
}
