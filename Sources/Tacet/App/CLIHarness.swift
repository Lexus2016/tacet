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

        #if DEBUG
        if arguments.contains("--check-ollama-auth") {
            Task {
                guard let spec = ProviderCatalog.spec("ollamaCloud"),
                      let url = spec.endpoint("chat/completions") else { exit(2) }
                guard let key = Keychain.string(spec.keychainAccount) else {
                    print("Ollama Cloud has no readable Keychain entry.")
                    exit(3)
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 12
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                spec.setHeaders(on: &request, key: key)
                request.httpBody = Data(#"{"model":"tacet-audit-intentionally-nonexistent-model","messages":[{"role":"user","content":"diagnostic"}]}"#.utf8)
                do {
                    let (_, response) = try await SharedSession.cloud.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    print("Ollama Cloud Keychain authentication: HTTP \(status).")
                    exit(status == 404 ? 0 : 4)
                } catch {
                    print("Ollama Cloud connection failed.")
                    exit(5)
                }
            }
            return true
        }
        if arguments.contains("--check-editor-input") {
            Task {
                let expectedApp = value(after: "--app", in: arguments)
                let expectedSelection = value(after: "--selection", in: arguments)
                await checkEditorInput(appID: expectedApp, selection: expectedSelection,
                                       probeOnly: arguments.contains("--probe-copy"))
            }
            return true
        }
        #endif

        if arguments.contains("--preview-hud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                HUDController.shared.showRecording()
                HUDController.shared.updateLevel(0.75)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                exit(0)
            }
            return false
        }

        if let path = value(after: "--render-hud", in: arguments) {
            let theme = IndicatorTheme(rawValue: value(after: "--theme", in: arguments) ?? "glass") ?? .glass
            Task {
                let hud = HUDController.shared
                if arguments.contains("--processing") {
                    hud.showProcessing(theme: theme)
                } else {
                    hud.showRecording(theme: theme)
                    hud.updateLevel(0.55)
                }
                try? await Task.sleep(for: .milliseconds(240))
                let rendered = hud.previewWindow.map { render($0, to: path) } ?? false
                hud.hide()
                exit(rendered ? 0 : 1)
            }
            return true
        }

        if arguments.contains("--check-hotkey") {
            let settings = AppSettings.shared
            let preset = HotkeyPreset.matching(keyCode: settings.hotkeyKeyCode,
                                               modifiers: settings.hotkeyModifiers) ?? .controlOptionSpace
            let manager = HotkeyManager()
            print("mode: \(settings.hotkeyMode)")
            for candidate in [preset] + HotkeyPreset.allCases.filter({ $0 != preset }) {
                if manager.register(keyCode: candidate.keyCode, modifiers: candidate.modifiers) {
                    print("registered: \(candidate.title)")
                    exit(0)
                }
                print("taken: \(candidate.title)")
            }
            print("no free hotkey")
            exit(1)
        }

        if let index = arguments.firstIndex(of: "--render-ui"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    NSLog("render timed out")
                    exit(2)
                }
                let tab = SettingsView.Tab(rawValue: value(after: "--tab", in: arguments) ?? "") ?? .general
                let appearance = value(after: "--appearance", in: arguments) == "dark" ? NSAppearance.Name.darkAqua : .aqua
                let window = arguments.contains("--history") ? makeHistoryWindow(entries: sampleEntries()) : makeSettingsWindow(tab: tab)
                if arguments.contains("--minimum-size") {
                    window.setContentSize(arguments.contains("--history") ? AppWindows.historyMinimum : AppWindows.settingsMinimum)
                }
                window.appearance = NSAppearance(named: appearance)
                if !render(window, to: path) { exit(1) }
                exit(0)
            }
            return true
        }

        if arguments.contains("--preview-ui") || arguments.contains("--preview-history") {
            let tab = SettingsView.Tab(rawValue: value(after: "--tab", in: arguments) ?? "") ?? .general
            DispatchQueue.main.async {
                let window = arguments.contains("--preview-history")
                    ? makeHistoryWindow(entries: sampleEntries())
                    : makeSettingsWindow(tab: tab)
                previewWindow = window
                NSApp.setActivationPolicy(.regular)
                TacetIcon.applyToDock()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                if arguments.contains("--trace-window") {
                    traceWindowFrame(window)
                    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated { traceWindowFrame(window) }
                    }
                }
            }
            return true
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

        if let index = arguments.firstIndex(of: "--record"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            Task {
                let capture = AudioCaptureService()
                do {
                    try capture.start()
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    let result = try capture.stop()
                    if let result {
                        let attributes = try? FileManager.default.attributesOfItem(atPath: result.url.path)
                        let size = (attributes?[.size] as? Int) ?? 0
                        print(String(format: "recorded %.2f s, rms %.5f, peak %.3f, file %d bytes",
                                     result.duration, result.rms, result.peak, size))
                        print(result.url.path)
                    } else {
                        print("nothing recorded")
                    }
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                exit(0)
            }
            return true
        }

        if let index = arguments.firstIndex(of: "--pipeline"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            let target = value(after: "--to", in: arguments)
            Task {
                await runPipeline(path: path, target: target)
                exit(0)
            }
            return true
        }

        if let index = arguments.firstIndex(of: "--edit"), index + 1 < arguments.count {
            let selection = arguments[index + 1]
            let instruction = value(after: "--instruction", in: arguments) ?? ""
            Task {
                let settings = AppSettings.shared
                let configuration = CleanupConfiguration(
                    provider: settings.cleanupProvider,
                    baseURL: settings.openAIChatBaseURL,
                    model: settings.chatModel(for: settings.cleanupProvider),
                    timeout: max(6, settings.cleanupTimeout + 4)
                )
                let started = Date()
                let outcome = await SelectionEditor().edit(selection: selection,
                                                           instruction: instruction,
                                                           configuration: configuration)
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "edit: %@  (%.2f s)", outcome == nil ? "failed" : "ok", elapsed))
                print(outcome?.text.isEmpty == true ? "<deleted>" : (outcome?.text ?? "<nil>"))
                exit(0)
            }
            return true
        }

        if let index = arguments.firstIndex(of: "--translate"), index + 1 < arguments.count {
            let text = arguments[index + 1]
            let target = value(after: "--to", in: arguments) ?? "en"
            Task {
                let settings = AppSettings.shared
                let configuration = CleanupConfiguration(
                    provider: settings.cleanupProvider,
                    baseURL: settings.openAIChatBaseURL,
                    model: settings.chatModel(for: settings.cleanupProvider),
                    timeout: max(4, settings.cleanupTimeout + 2)
                )
                if let spec = ProviderCatalog.spec(configuration.provider) {
                    print("provider: \(spec.id), model: \(configuration.model), base: \(spec.baseURL)")
                    print("key present: \(ProviderCatalog.key(for: spec) != nil), detected: \(TextLanguage.detect(text) ?? "?")")
                }
                let started = Date()
                let outcome = await Translator().translate(text, to: target, configuration: configuration)
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "translated: %@  (%.2f s)", outcome.translated ? "yes" : "no", elapsed))
                print(outcome.text)
                exit(0)
            }
            return true
        }

        if let index = arguments.firstIndex(of: "--benchmark"), index + 2 < arguments.count {
            let path = arguments[index + 1]
            let count = Int(arguments[index + 2]) ?? 3
            Task {
                await benchmark(path: path, count: count)
                exit(0)
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

    #if DEBUG
    private static func checkEditorInput(appID: String?, selection: String?, probeOnly: Bool) async {
        guard TextInserter.isAccessibilityTrusted() else {
            print("Accessibility is unavailable for this build.")
            exit(2)
        }
        guard let appID, let selection, selection.hasPrefix("Tacet audit "), let focus = SelectionReader.Focus(),
              focus.application.bundleIdentifier == appID else {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unavailable"
            print("The dedicated editor fixture is not focused (frontmost: \(frontmost)).")
            exit(3)
        }

        let before = pasteboardContent()
        let captured = await SelectionReader.read(in: focus)
        if probeOnly {
            switch captured {
            case .none: print("Selection: none.")
            case .unreadable: print("Selection: unreadable.")
            case .text(let text, let range):
                print("Selection: text; exact fixture: \(text == selection); trailing newline: \(text.last?.isNewline == true); range exposed: \(range != nil).")
            }
            exit(before == pasteboardContent() ? 0 : 5)
        }
        guard case .text(let text, _) = captured, text == selection else {
            print("The selected fixture could not be read.")
            exit(4)
        }
        guard before == pasteboardContent() else {
            print("Clipboard changed after reading the selection.")
            exit(5)
        }
        guard await TextInserter.paste("Tacet audit replacement verified.", in: focus),
              before == pasteboardContent() else {
            print("Could not post the replacement and preserve the clipboard.")
            exit(6)
        }
        print("Selection read, replacement posted, clipboard contents verified.")
        exit(0)
    }

    private static func pasteboardContent() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }
    #endif

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Windows

    private static func traceWindowFrame(_ window: NSWindow) {
        let line = "Window frame: \(NSStringFromRect(window.frame))\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private static func makeSettingsWindow(tab: SettingsView.Tab) -> NSWindow {
        AppWindows.makeWindow(title: String(localized: "Tacet Settings"),
                              size: AppWindows.settingsSize, minimum: AppWindows.settingsMinimum) {
            SettingsView(initialTab: tab).environmentObject(DictationController.shared)
        }
    }

    private static func makeHistoryWindow(entries: [HistoryEntry]) -> NSWindow {
        AppWindows.makeWindow(title: String(localized: "Tacet History"),
                              size: AppWindows.historySize, minimum: AppWindows.historyMinimum) {
            HistoryView(entries: entries).environmentObject(DictationController.shared)
        }
    }

    /// Renders the settings window off-screen and writes a PNG.
    private static func render(_ window: NSWindow, to path: String) -> Bool {
        guard let hosting = window.contentView else { return false }
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("could not allocate a bitmap")
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("could not encode a PNG")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return true
        } catch {
            print("write failed: \(error.localizedDescription)")
            return false
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

    // MARK: Benchmark

    private static func benchmark(path: String, count: Int) async {
        guard let clip = try? AudioClip.load(url: URL(fileURLWithPath: path)) else {
            print("cannot read \(path)")
            return
        }

        let settings = AppSettings.shared
        let pipelineSettings = PipelineSettings(
            languageOverride: settings.languageOverride,
            engineOrder: settings.activeEngineOrder,
            dualLanguageCheck: false,
            cloudTimeout: settings.cloudTimeout
        )
        let engines = settings.engineConfiguration

        print("audio: \(String(format: "%.2f", clip.duration)) s, runs: \(count)")
        var times: [Double] = []

        for run in 1...count {
            let started = Date()
            let result = await TranscriptionPipeline().transcribe(clip, settings: pipelineSettings, engines: engines)
            let elapsed = Date().timeIntervalSince(started)
            times.append(elapsed)

            switch result {
            case .success(let output):
                print(String(format: "run %d: %.3f s  (%@)", run, elapsed, output.transcript.engine))
            case .failure(let failure):
                print(String(format: "run %d: %.3f s  failed: %@", run, elapsed, failure.localizedDescription))
            }
        }

        if let first = times.first, let best = times.min(), times.count > 1 {
            print(String(format: "first: %.3f s, best: %.3f s, saved by a warm connection: %.0f ms",
                         first, best, (first - best) * 1000))
        }
    }

    private static func runPipeline(path: String, target: String?) async {
        guard let clip = try? AudioClip.load(url: URL(fileURLWithPath: path)) else {
            print("cannot read \(path)")
            return
        }

        let settings = AppSettings.shared
        let pipelineSettings = PipelineSettings(
            languageOverride: settings.languageOverride,
            engineOrder: settings.activeEngineOrder,
            dualLanguageCheck: settings.dualLanguageCheck,
            cloudTimeout: settings.cloudTimeout
        )
        let engines = settings.engineConfiguration
        let configuration = CleanupConfiguration(
            provider: settings.cleanupProvider,
            baseURL: settings.openAIChatBaseURL,
            model: settings.chatModel(for: settings.cleanupProvider),
            timeout: settings.cleanupTimeout
        )

        print(String(format: "audio: %.1f s", clip.duration))

        let t0 = Date()
        let result = await TranscriptionPipeline().transcribe(clip, settings: pipelineSettings, engines: engines)
        let asrTime = Date().timeIntervalSince(t0)

        guard case .success(let output) = result else {
            if case .failure(let failure) = result { print("ASR failed: \(failure.localizedDescription)") }
            return
        }

        var text = output.transcript.text
        print(String(format: "ASR %@ %.2f s, lang %@", output.transcript.engine, asrTime, output.transcript.language ?? "?"))
        print("raw: \(text)")

        if settings.isCleanupConfigured {
            let t1 = Date()
            let cleaned = await CleanupPipeline().clean(text, configuration: configuration)
            print(String(format: "cleanup %@ %.2f s, changed %@",
                         cleaned.engine, Date().timeIntervalSince(t1), cleaned.changed ? "yes" : "no"))
            text = cleaned.text
            print("clean: \(text)")
        }

        if let target {
            let t2 = Date()
            let outcome = await Translator().translate(text, to: target, configuration: configuration)
            print(String(format: "translate %.2f s, ok %@",
                         Date().timeIntervalSince(t2), outcome.translated ? "yes" : "no"))
            text = outcome.text
        }

        print("final: \(text)")
    }

    private static func transcribe(path: String, languageOverride: String?, engineOrder: [String]?) async {        let url = URL(fileURLWithPath: path)
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
                engineOrder: engineOrder ?? settings.activeEngineOrder,
                dualLanguageCheck: settings.dualLanguageCheck,
                cloudTimeout: settings.cloudTimeout
            )
            let engines = settings.engineConfiguration

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
