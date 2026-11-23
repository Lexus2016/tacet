import AppKit
import Foundation
import SwiftUI

/// Diagnostic entry points, useful for regression tests and for checking an
/// engine without using the microphone:
///
///   Tacet --transcribe file.wav [--language en] [--engine parakeet]
///   Tacet --prepare-parakeet
///   Tacet --preview-ui [--tab engines]
///   Tacet --preview-history
///   Tacet --render-ui out.png
@MainActor
enum CLIHarness {
    static var previewWindow: NSWindow?

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments

        if let index = arguments.firstIndex(of: "--render-ui"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    NSLog("render timed out")
                    exit(2)
                }
                renderSettings(to: path)
                exit(0)
            }
            return true
        }

        if arguments.contains("--preview-ui") {
            let tab = SettingsView.Tab(rawValue: value(after: "--tab", in: arguments) ?? "") ?? .general
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate()
                let window = makeSettingsWindow(tab: tab)
                previewWindow = window
                window.makeKeyAndOrderFront(nil)
            }
            return false
        }

        if arguments.contains("--preview-history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate()
                let window = makeHistoryWindow(entries: sampleEntries())
                previewWindow = window
                window.makeKeyAndOrderFront(nil)
            }
            return false
        }

        if arguments.contains("--prepare-parakeet") {
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

        if let index = arguments.firstIndex(of: "--transcribe"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            let language = value(after: "--language", in: arguments)
            let engine = value(after: "--engine", in: arguments)
            Task {
                await transcribe(path: path, languageOverride: language, engineOrder: engine.map { [$0] })
                exit(0)
            }
            return true
        }

        return false
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Windows

    private static func makeSettingsWindow(tab: SettingsView.Tab) -> NSWindow {
        let root = SettingsView(initialTab: tab).environmentObject(DictationController.shared)
        return wrap(root, size: NSSize(width: 620, height: 660), title: "Tacet Settings")
    }

    private static func makeHistoryWindow(entries: [HistoryEntry]) -> NSWindow {
        let root = HistoryView(entries: entries).environmentObject(DictationController.shared)
        return wrap(root, size: NSSize(width: 900, height: 600), title: "Tacet History")
    }

    private static func wrap<Content: View>(_ root: Content, size: NSSize, title: String) -> NSWindow {
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hosting
        window.center()
        window.level = .floating // harness only: keeps the preview above the terminal
        return window
    }

    /// Renders the settings window off-screen and writes a PNG.
    static func renderSettings(to path: String) {
        let window = makeSettingsWindow(tab: .general)
        guard let hosting = window.contentView else { return }
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("could not allocate a bitmap")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("could not encode a PNG")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            print("write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Demo data

    private static func sampleEntries() -> [HistoryEntry] {
        let now = Date()
        func entry(_ text: String,
                   _ engine: String,
                   _ language: String,
                   _ app: String,
                   minutesAgo: Double,
                   status: HistoryEntry.Status = .ok,
                   cleanup: String? = "groq") -> HistoryEntry {
            HistoryEntry(
                id: UUID().uuidString,
                createdAt: now.addingTimeInterval(-minutesAgo * 60),
                text: text,
                rawText: status == .ok ? text.lowercased() : nil,
                engine: engine,
                language: language,
                duration: 4.2,
                latency: 0.82,
                appName: app,
                audioPath: nil,
                status: status,
                inserted: status == .ok,
                cleanupEngine: cleanup
            )
        }

        return [
            entry("Додай, будь ласка, у п'ятницю зустріч з командою о десятій ранку.", "groq", "uk", "Telegram", minutesAgo: 3),
            entry("Remind me to review the release notes before the demo.", "groq", "en", "Mail", minutesAgo: 17),
            entry("Скинь мені, пожалуйста, последнюю версию документа.", "parakeet", "ru", "Slack", minutesAgo: 42),
            entry("", "none", "none", "Cursor", minutesAgo: 61, status: .unrecovered, cleanup: nil),
            entry("Купи каву та молоко дорогою додому.", "parakeet", "uk", "Notes", minutesAgo: 95),
            entry("The quick brown fox jumps over the lazy dog, again and again.", "openai", "en", "Safari", minutesAgo: 140),
        ]
    }

    // MARK: Transcription

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
