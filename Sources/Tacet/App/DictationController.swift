import AVFoundation
import AppKit
import Foundation

@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case recording
        case processing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var hotkeyConflict = false
    @Published private(set) var statusNote: String = "Ready"
    @Published private(set) var lastFailure: String?

    private let settings = AppSettings.shared
    private let store = HistoryStore.shared
    private let capture = AudioCaptureService()
    private let pipeline = TranscriptionPipeline()
    private let cleanupPipeline = CleanupPipeline()
    private let hotkey = HotkeyManager()

    private var isStarting = false
    private var noteTask: Task<Void, Never>?

    private init() {
        capture.levelHandler = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                self.level = level
                HUDController.shared.updateLevel(level)
            }
        }
        capture.configurationChangeHandler = { [weak self] in
            self?.status("Input device changed, stopping")
            self?.stopRecording()
        }
        configureHotkey()
        refreshHistory()
        purgeAudio()
        adoptOrphanRecordings()
    }

    /// A recording written to disk with no history row means the app died
    /// between capture and transcription. Adopt it instead of leaving an
    /// invisible file behind.
    private func adoptOrphanRecordings() {
        let known = store.knownAudioPaths()
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        for url in AudioStore.recentRecordings(modifiedAfter: cutoff) where !known.contains(url.path) {
            _ = store.insert(text: "",
                             rawText: nil,
                             engine: nil,
                             language: nil,
                             duration: AudioStore.duration(of: url),
                             latency: 0,
                             appName: nil,
                             audioPath: url.path,
                             status: .unrecovered,
                             cleanupEngine: nil)
        }
    }

    // MARK: Hotkey

    func configureHotkey() {
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }

        let preset = HotkeyPreset.matching(keyCode: settings.hotkeyKeyCode,
                                           modifiers: settings.hotkeyModifiers) ?? .optionSpace
        hotkeyConflict = !hotkey.register(keyCode: preset.keyCode, modifiers: preset.modifiers)
        if hotkeyConflict {
            status("Hotkey is taken by another app")
        }
    }

    private func hotkeyPressed() {
        guard phase == .idle || phase == .recording else { return }
        if settings.hotkeyMode == "hold" {
            if phase == .idle { startRecording() }
        } else {
            toggle()
        }
    }

    private func hotkeyReleased() {
        guard settings.hotkeyMode == "hold", phase == .recording else { return }
        stopRecording()
    }

    func toggle() {
        if phase == .recording {
            stopRecording()
        } else if phase == .idle {
            startRecording()
        }
    }

    // MARK: Recording

    func startRecording() {
        guard phase != .recording, !isStarting else { return }
        isStarting = true

        Task {
            defer { isStarting = false }

            guard await ensureMicrophone() else {
                status("Microphone access denied")
                return
            }

            do {
                try capture.start()
                phase = .recording
                lastFailure = nil
                status("Recording…")
                if settings.playSounds { NSSound(named: "Tink")?.play() }
                if settings.showHUD { HUDController.shared.showRecording() }
            } catch {
                phase = .idle
                lastFailure = error.localizedDescription
                status(error.localizedDescription)
                if settings.showHUD {
                    HUDController.shared.showMessage(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }

        let result: AudioCaptureService.Result
        do {
            guard let captured = try capture.stop() else { return }
            result = captured
        } catch {
            phase = .idle
            lastFailure = error.localizedDescription
            status(error.localizedDescription)
            HUDController.shared.hide()
            return
        }

        phase = .processing
        status("Transcribing…")
        if settings.playSounds { NSSound(named: "Pop")?.play() }
        if settings.showHUD { HUDController.shared.showProcessing() }

        let clip = AudioClip(url: result.url, duration: result.duration, samples: result.samples)

        if clip.isSilent {
            phase = .idle
            AudioStore.delete(path: result.url.path)
            status("No speech detected")
            HUDController.shared.hide()
            return
        }

        Task { await process(clip: clip, existingEntryID: nil) }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        capture.cancel()
        phase = .idle
        status("Cancelled")
        HUDController.shared.hide()
    }

    // MARK: Processing

    private func process(clip: AudioClip, existingEntryID: String?) async {
        let started = Date()
        let appName = TextInserter.frontmostAppName

        let engineConfiguration = EngineConfiguration(
            groqModel: settings.groqModel,
            openAIBaseURL: settings.openAIBaseURL,
            openAIModel: settings.openAIModel,
            cloudTimeout: settings.cloudTimeout
        )
        let pipelineSettings = PipelineSettings(
            languageOverride: settings.languageOverride,
            engineOrder: settings.engineOrder,
            dualLanguageCheck: settings.dualLanguageCheck,
            cloudTimeout: settings.cloudTimeout
        )

        let result = await pipeline.transcribe(clip, settings: pipelineSettings, engines: engineConfiguration)

        switch result {
        case .success(let output):
            var text = output.transcript.text
            var cleanupEngine: String?

            if settings.isCleanupConfigured {
                let secondary = settings.cleanupProvider == KeychainAccount.groq
                    ? (Keychain.secret(KeychainAccount.openAI, environment: "OPENAI_API_KEY") != nil ? KeychainAccount.openAI : nil)
                    : (Keychain.secret(KeychainAccount.groq, environment: "GROQ_API_KEY") != nil ? KeychainAccount.groq : nil)

                let configuration = CleanupConfiguration(
                    provider: settings.cleanupProvider,
                    baseURL: settings.cleanupBaseURL,
                    model: settings.cleanupModel,
                    timeout: settings.cleanupTimeout,
                    secondaryProvider: secondary
                )
                let cleaned = await cleanupPipeline.clean(text, configuration: configuration)
                if cleaned.changed {
                    text = cleaned.text
                    cleanupEngine = cleaned.engine
                }
            }

            deliver(text: text,
                    raw: output.transcript.text,
                    transcript: output.transcript,
                    clip: clip,
                    latency: Date().timeIntervalSince(started),
                    appName: appName,
                    cleanupEngine: cleanupEngine,
                    existingEntryID: existingEntryID)

        case .failure(let failure):
            recordFailure(failure,
                          clip: clip,
                          latency: Date().timeIntervalSince(started),
                          appName: appName,
                          existingEntryID: existingEntryID)
        }
    }

    private func deliver(text: String,
                         raw: String,
                         transcript: Transcript,
                         clip: AudioClip,
                         latency: TimeInterval,
                         appName: String?,
                         cleanupEngine: String?,
                         existingEntryID: String?) {
        TextInserter.copy(text)
        let pasted = settings.pasteAutomatically && TextInserter.paste()

        let entryID: String
        if let existingEntryID, store.entry(id: existingEntryID) != nil {
            entryID = existingEntryID
            store.update(id: existingEntryID,
                         text: text,
                         rawText: raw,
                         engine: transcript.engine,
                         language: transcript.language,
                         latency: latency,
                         status: .ok,
                         cleanupEngine: cleanupEngine)
        } else {
            let entry = store.insert(text: text,
                                     rawText: raw,
                                     engine: transcript.engine,
                                     language: transcript.language,
                                     duration: clip.duration,
                                     latency: latency,
                                     appName: appName,
                                     audioPath: clip.url.path,
                                     status: .ok,
                                     cleanupEngine: cleanupEngine)
            entryID = entry.id
        }

        if pasted {
            store.markInserted(id: entryID)
            status("Inserted")
            if settings.showHUD { HUDController.shared.showMessage(pasted ? "Inserted" : "Copied", isError: false) }
        } else {
            status("Copied to clipboard, press ⌘V")
            if settings.showHUD { HUDController.shared.showMessage("Copied, press ⌘V", isError: false) }
        }

        phase = .idle
        lastFailure = nil
        refreshHistory()
    }

    private func recordFailure(_ failure: PipelineFailure,
                               clip: AudioClip,
                               latency: TimeInterval,
                               appName: String?,
                               existingEntryID: String?) {
        let message = failure.localizedDescription

        if let existingEntryID, store.entry(id: existingEntryID) != nil {
            store.update(id: existingEntryID,
                         text: "",
                         rawText: nil,
                         engine: nil,
                         language: nil,
                         latency: latency,
                         status: .unrecovered,
                         cleanupEngine: nil)
        } else {
            _ = store.insert(text: "",
                             rawText: nil,
                             engine: nil,
                             language: nil,
                             duration: clip.duration,
                             latency: latency,
                             appName: appName,
                             audioPath: clip.url.path,
                             status: .unrecovered,
                             cleanupEngine: nil)
        }

        phase = .idle
        lastFailure = message
        status("Failed: \(message)")
        if settings.showHUD { HUDController.shared.showMessage("Not transcribed, recording kept", isError: true) }
        if settings.playSounds { NSSound(named: "Basso")?.play() }
        refreshHistory()
    }

    // MARK: History actions

    func copyLast() {
        guard let last = store.last(), !last.text.isEmpty else {
            status("Nothing to copy yet")
            return
        }
        TextInserter.copy(last.text)
        status("Last dictation copied")
        if settings.showHUD { HUDController.shared.showMessage("Copied last dictation", isError: false) }
    }

    func copy(_ entry: HistoryEntry) {
        guard !entry.text.isEmpty else { return }
        TextInserter.copy(entry.text)
        status("Copied")
    }

    func retry(_ entry: HistoryEntry) {
        guard let url = entry.audioURL, FileManager.default.fileExists(atPath: url.path) else {
            status("The recording is gone")
            return
        }
        guard phase == .idle else { return }

        phase = .processing
        status("Retrying…")
        if settings.showHUD { HUDController.shared.showProcessing() }

        Task {
            do {
                let clip = try AudioClip.load(url: url)
                await process(clip: clip, existingEntryID: entry.id)
            } catch {
                phase = .idle
                status(error.localizedDescription)
                HUDController.shared.hide()
            }
        }
    }

    func delete(_ entry: HistoryEntry) {
        if let path = store.delete(id: entry.id) {
            AudioStore.delete(path: path)
        }
        refreshHistory()
    }

    func deleteAll() {
        for entry in store.entries(limit: 10_000) {
            if let path = store.delete(id: entry.id) {
                AudioStore.delete(path: path)
            }
        }
        refreshHistory()
    }

    func refreshHistory() {
        history = store.entries(limit: 500)
    }

    func purgeAudio() {
        AudioStore.purge(olderThanDays: settings.keepAudioDays, keeping: AudioStore.unrecoveredPaths())
    }

    // MARK: Helpers

    private func status(_ text: String) {
        statusNote = text
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.phase == .idle, self.lastFailure == nil { self.statusNote = "Ready" }
            }
        }
    }

    private func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "waveform.circle.fill"
        case .processing: return "ellipsis.circle"
        case .idle: return lastFailure == nil ? "mic.circle" : "exclamationmark.circle"
        }
    }
}
