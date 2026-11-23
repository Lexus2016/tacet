import Foundation

/// Diagnostic entry points, useful for regression tests and for checking an
/// engine without using the microphone:
///
///   Tacet --transcribe file.wav [--language en] [--engine parakeet]
///   Tacet --prepare-parakeet
@MainActor
enum CLIHarness {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments

        if let index = arguments.firstIndex(of: "--prepare-parakeet") {
            _ = index
            Task {
                do {
                    print("Downloading and loading Parakeet…")
                    try await ParakeetRecognizer.shared.downloadIfNeeded()
                    print("Ready.")
                    exit(0)
                } catch {
                    print("Failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }

        guard let index = arguments.firstIndex(of: "--transcribe"), index + 1 < arguments.count else {
            return false
        }

        let path = arguments[index + 1]
        var language: String?
        if let languageIndex = arguments.firstIndex(of: "--language"), languageIndex + 1 < arguments.count {
            language = arguments[languageIndex + 1]
        }
        var engineOrder: [String]?
        if let engineIndex = arguments.firstIndex(of: "--engine"), engineIndex + 1 < arguments.count {
            engineOrder = [arguments[engineIndex + 1]]
        }

        Task {
            await transcribe(path: path, languageOverride: language, engineOrder: engineOrder)
            exit(0)
        }
        return true
    }

    private static func transcribe(path: String, languageOverride: String?, engineOrder: [String]?) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("No such file: \(path)")
            return
        }

        do {
            let clip = try AudioClip.load(url: url)
            print(String(format: "audio: %.2f s, silent: %@, samples: %d",
                         clip.duration, clip.isSilent ? "yes" : "no", clip.samples.count))

            let settings = AppSettings.shared
            let pipelineSettings = PipelineSettings(
                languageOverride: languageOverride ?? settings.languageOverride,
                engineOrder: engineOrder ?? settings.engineOrder,
                dualLanguageCheck: settings.dualLanguageCheck,
                cloudTimeout: settings.cloudTimeout
            )
            let engines = EngineConfiguration(
                groqModel: settings.groqModel,
                openAIBaseURL: settings.openAIBaseURL,
                openAIModel: settings.openAIModel,
                cloudTimeout: settings.cloudTimeout
            )

            let started = Date()
            let result = await TranscriptionPipeline().transcribe(clip, settings: pipelineSettings, engines: engines)
            let elapsed = Date().timeIntervalSince(started)

            switch result {
            case .success(let output):
                print(String(format: "engine: %@  language: %@  score: %.3f  latency: %.2f s (total %.2f s)",
                             output.transcript.engine,
                             output.transcript.language ?? "?",
                             output.transcript.score,
                             output.transcript.latency,
                             elapsed))
                for attempt in output.attempts {
                    print("  attempt \(attempt.engine): \(attempt.error ?? "ok")")
                }
                print("---")
                print(output.transcript.text)
            case .failure(let failure):
                print("failed after \(String(format: "%.2f", elapsed)) s")
                for attempt in failure.attempts {
                    print("  attempt \(attempt.engine): \(attempt.error ?? "ok")")
                }
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
