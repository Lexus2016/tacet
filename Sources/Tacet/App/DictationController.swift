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
    private let languageMemory = LanguageMemory()

    private var isStarting = false
    private var hotkeyIsDown = false
    private var noteTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    /// The combination actually registered, which may differ from the stored
    /// one when another app owns it. Formatted for display.
    private(set) var activeHotkey: String = ""
    /// The app that was frontmost when the recording started. The text belongs
    /// there even if the user switches windows while it is being transcribed.
    private var targetApplication: NSRunningApplication?

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
        recoverPendingRecordings()
        prewarmLocalEngine()
    }

    /// Load the local fallback while the app is idle, so the first dictation
    /// does not pay for it. Released again after ten quiet minutes.
    private func prewarmLocalEngine() {
        CloudWarmup.warm()
        guard ParakeetRecognizer.shared.isConfigured() else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard phase == .idle else { return }
            try? await ParakeetRecognizer.shared.warmUp()
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .idle else { return }
            await ParakeetRecognizer.shared.unload()
        }
    }

    /// Dictations that failed earlier (a killed process, an outage) are retried
    /// on launch instead of waiting for the user to notice them in History.
    private func recoverPendingRecordings() {
        let pending = store.entries(limit: 100).filter {
            $0.status == .unrecovered && ($0.audioPath?.isEmpty == false)
        }
        guard !pending.isEmpty else { return }

        recoveryTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            for entry in pending {
                guard !Task.isCancelled,
                      phase == .idle,
                      let url = entry.audioURL
                else { break }
                guard FileManager.default.fileExists(atPath: url.path),
                      let clip = try? AudioClip.load(url: url)
                else { continue }

                // A silent recording is nothing to recover: drop it and clear
                // the pending badge instead of retrying it forever.
                if clip.isSilent || clip.peak < 0.01 {
                    _ = store.delete(id: entry.id)
                    AudioStore.delete(path: url.path)
                    refreshHistory()
                    continue
                }

                await process(clip: clip,
                              existingEntryID: entry.id,
                              allowPaste: false,
                              allowClipboard: false,
                              autoRetry: false)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
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
        hotkey.onCancel = { [weak self] in self?.cancelModifierPress() }

        // A single modifier cannot be a Carbon hotkey; it is monitored through
        // flagsChanged and always behaves as push-to-talk.
        if settings.hotkeyKeyCode == 0, settings.hotkeyModifiers != 0 {
            let flags = HotkeyFormat.eventFlags(from: settings.hotkeyModifiers)
            if hotkey.registerModifierOnly(flags) {
                activeHotkey = HotkeyFormat.title(modifiers: settings.hotkeyModifiers, label: "")
                hotkeyConflict = false
                status("Hold \(activeHotkey) to dictate")
            } else {
                activeHotkey = ""
                hotkeyConflict = true
                status("Modifier-only hotkey needs Accessibility permission")
            }
            return
        }

        let preferred = HotkeyFormat.title(modifiers: settings.hotkeyModifiers,
                                           label: settings.hotkeyLabel)

        if hotkey.register(keyCode: UInt32(settings.hotkeyKeyCode),
                           modifiers: UInt32(settings.hotkeyModifiers)) {
            activeHotkey = preferred
            hotkeyConflict = false
            NSLog("Tacet: hotkey %@ registered", preferred)
            return
        }
        NSLog("Tacet: hotkey %@ is taken (eventHotKeyExistsErr)", preferred)

        // The chosen combination is owned by another app. Find a free one
        // instead of leaving the app without a way to start dictation.
        for preset in HotkeyPreset.allCases {
            if hotkey.register(keyCode: preset.keyCode, modifiers: preset.modifiers) {
                activeHotkey = preset.title
                hotkeyConflict = false
                status("\(preferred) is taken, using \(preset.title)")
                return
            }
        }

        activeHotkey = ""
        hotkeyConflict = true
        status("No free hotkey, record another in Settings")
    }

    private func hotkeyPressed() {
        hotkeyIsDown = true
        guard phase == .idle || phase == .recording else { return }

        if settings.hotkeyKeyCode == 0 {
            if phase == .idle { startRecording() }
            return
        }

        if settings.hotkeyMode == "hold" {
            if phase == .idle { startRecording() }
        } else {
            toggle()
        }
    }

    private func hotkeyReleased() {
        hotkeyIsDown = false
        guard phase == .recording else { return }

        if settings.hotkeyKeyCode == 0 {
            stopRecording()
            return
        }

        guard settings.hotkeyMode == "hold" else { return }
        stopRecording()
    }

    /// The modifier was only part of a shortcut (Command-C): throw the empty
    /// recording away without a sound or a message.
    private func cancelModifierPress() {
        guard phase == .recording else { return }
        capture.cancel()
        phase = .idle
        status("Ready")
        HUDController.shared.hide()
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
        guard phase == .idle, !isStarting else { return }
        isStarting = true

        // The microphone always wins over background recovery and model
        // housekeeping.
        recoveryTask?.cancel()
        recoveryTask = nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        Task {
            defer { isStarting = false }

            guard await ensureMicrophone() else {
                status("Microphone access denied")
                return
            }

            do {
                targetApplication = NSWorkspace.shared.frontmostApplication
                try capture.start()
                phase = .recording
                lastFailure = nil
                status("Recording…")
                if settings.playSounds { SoundService.shared.play(.start, style: settings.soundStyle) }
                if settings.showHUD { HUDController.shared.showRecording() }

                // The key may have been released while the microphone
                // permission prompt was on screen.
                if settings.hotkeyMode == "hold", !hotkeyIsDown {
                    stopRecording()
                }
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
        if settings.showHUD { HUDController.shared.showProcessing() }

        let clip = AudioClip(url: result.url, duration: result.duration, samples: result.samples)

        if clip.duration < 0.25 {
            phase = .idle
            AudioStore.delete(path: result.url.path)
            status("No speech detected")
            HUDController.shared.hide()
            return
        }

        if result.rms < 0.0016, result.peak < 0.01 {
            phase = .idle
            AudioStore.delete(path: result.url.path)
            status("No speech detected")
            HUDController.shared.hide()
            return
        }

        Task { await process(clip: clip,
                             existingEntryID: nil,
                             allowPaste: true,
                             allowClipboard: true,
                             autoRetry: true) }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        capture.cancel()
        phase = .idle
        status("Cancelled")
        HUDController.shared.hide()
    }

    // MARK: Processing

    private func process(clip: AudioClip,
                         existingEntryID: String?,
                         allowPaste: Bool,
                         allowClipboard: Bool,
                         autoRetry: Bool) async {
        let started = Date()
        let appName = TextInserter.frontmostAppName

        let engineConfiguration = EngineConfiguration(
            groqModel: settings.groqModel,
            openAIBaseURL: settings.openAIBaseURL,
            openAIModel: settings.openAIModel,
            cloudTimeout: settings.cloudTimeout
        )
        let expectedLanguage: String? = targetApplication
            .flatMap { $0.bundleIdentifier }
            .flatMap { languageMemory.language(for: $0) }

        let pipelineSettings = PipelineSettings(
            languageOverride: settings.languageOverride,
            engineOrder: settings.engineOrder,
            dualLanguageCheck: settings.dualLanguageCheck,
            cloudTimeout: settings.cloudTimeout,
            expectedLanguage: expectedLanguage,
            voiceLanguageCheck: settings.voiceLanguageCheck,
            voiceLanguageModel: settings.openRouterModel,
            voiceLanguageCandidates: LanguageOption.allCases.filter { $0 != .auto }.map(\.rawValue)
        )

        let result = await pipeline.transcribe(clip, settings: pipelineSettings, engines: engineConfiguration)

        switch result {
        case .success(let output):
            var text = output.transcript.text
            var cleanupEngine: String?

            if settings.isCleanupConfigured,
               text.split(whereSeparator: \.isWhitespace).count >= 3 {
                let secondary = settings.cleanupProvider == KeychainAccount.groq
                    ? (Keychain.secret(KeychainAccount.openAI, environment: "OPENAI_API_KEY") != nil ? KeychainAccount.openAI : nil)
                    : (Keychain.secret(KeychainAccount.groq, environment: "GROQ_API_KEY") != nil ? KeychainAccount.groq : nil)

                let configuration = CleanupConfiguration(
                    provider: settings.cleanupProvider,
                    baseURL: settings.cleanupBaseURL,
                    model: settings.chatModel(for: settings.cleanupProvider),
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
                    existingEntryID: existingEntryID,
                    allowPaste: allowPaste,
                    allowClipboard: allowClipboard,
                    note: output.partial
                        ? "Partially transcribed: \(output.totalParts - output.failedParts) of \(output.totalParts) parts"
                        : nil)

        case .failure(let failure):
            recordFailure(failure,
                          clip: clip,
                          latency: Date().timeIntervalSince(started),
                          appName: appName,
                          existingEntryID: existingEntryID,
                          autoRetry: autoRetry)
        }
    }

    private func deliver(text: String,
                         raw: String,
                         transcript: Transcript,
                         clip: AudioClip,
                         latency: TimeInterval,
                         appName: String?,
                         cleanupEngine: String?,
                         existingEntryID: String?,
                         allowPaste: Bool,
                         allowClipboard: Bool,
                         note: String?) {
        // The entry may have been deleted while this transcribe was in flight.
        if let existingEntryID, store.entry(id: existingEntryID) == nil {
            phase = .idle
            return
        }

        let canPaste = allowPaste && allowClipboard && restoreTargetApplication()
        if allowClipboard {
            TextInserter.copy(text)
        }
        let pasted = canPaste && settings.pasteAutomatically && TextInserter.paste()

        if let bundleID = targetApplication?.bundleIdentifier,
           let language = transcript.language {
            languageMemory.remember(language, for: bundleID)
        }

        let entryID: String
        if let existingEntryID {
            entryID = existingEntryID
            store.setDuration(id: existingEntryID, duration: clip.duration)
            store.update(id: existingEntryID,
                         text: text,
                         rawText: raw,
                         engine: transcript.engine,
                         language: transcript.language,
                         latency: latency,
                         status: .ok,
                         cleanupEngine: cleanupEngine,
                         error: note)
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
                                     cleanupEngine: cleanupEngine,
                                     error: note)
            entryID = entry.id
        }

        if pasted {
            store.markInserted(id: entryID)
            status("Inserted")
            if settings.showHUD { HUDController.shared.showMessage("Inserted", isError: false) }
        } else if allowClipboard {
            status("Copied to clipboard, press ⌘V")
            if settings.showHUD { HUDController.shared.showMessage("Copied, press ⌘V", isError: false) }
        } else {
            status("Recovered — open History to copy")
            if settings.showHUD { HUDController.shared.showMessage("Recovered — in History", isError: false) }
        }

        phase = .idle
        lastFailure = nil
        refreshHistory()
        scheduleIdleUnload()
        if settings.playSounds { SoundService.shared.play(.success, style: settings.soundStyle) }
    }

    private func recordFailure(_ failure: PipelineFailure,
                               clip: AudioClip,
                               latency: TimeInterval,
                               appName: String?,
                               existingEntryID: String?,
                               autoRetry: Bool) {
        let message = failure.localizedDescription
        var failedID: String?

        if let existingEntryID {
            // Do not resurrect an entry the user deleted mid-retry.
            if store.entry(id: existingEntryID) != nil {
                store.update(id: existingEntryID,
                             text: "",
                             rawText: nil,
                             engine: nil,
                             language: nil,
                             latency: latency,
                             status: .unrecovered,
                             cleanupEngine: nil,
                             error: message)
                failedID = existingEntryID
            }
        } else {
            let entry = store.insert(text: "",
                                     rawText: nil,
                                     engine: nil,
                                     language: nil,
                                     duration: clip.duration,
                                     latency: latency,
                                     appName: appName,
                                     audioPath: clip.url.path,
                                     status: .unrecovered,
                                     cleanupEngine: nil,
                                     error: message)
            failedID = entry.id
        }

        phase = .idle
        lastFailure = message
        status("Failed: \(message)")
        if settings.showHUD { HUDController.shared.showMessage("Not transcribed, recording kept", isError: true) }
        if settings.playSounds { SoundService.shared.play(.error, style: settings.soundStyle) }
        refreshHistory()

        if autoRetry, let failedID {
            scheduleRetry(entryID: failedID, clip: clip)
        }
        scheduleIdleUnload()
    }

    /// One quiet retry a few seconds later. A flapping network is far more
    /// common than a real outage, and losing the thought is worse than one
    /// extra request.
    private func scheduleRetry(entryID: String, clip: AudioClip) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .idle else { return }
            await self.process(clip: clip,
                               existingEntryID: entryID,
                               allowPaste: false,
                               allowClipboard: false,
                               autoRetry: false)
        }
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
        guard phase == .idle, !isStarting else { return }

        phase = .processing
        status("Retrying…")
        if settings.showHUD { HUDController.shared.showProcessing() }

        Task {
            do {
                let clip = try AudioClip.load(url: url)
                await process(clip: clip,
                              existingEntryID: entry.id,
                              allowPaste: false,
                              allowClipboard: true,
                              autoRetry: false)
            } catch {
                phase = .idle
                store.update(id: entry.id,
                             text: entry.text,
                             rawText: entry.rawText,
                             engine: entry.engine,
                             language: entry.language,
                             latency: entry.latency,
                             status: entry.status,
                             cleanupEngine: entry.cleanupEngine,
                             error: error.localizedDescription)
                refreshHistory()
                lastFailure = error.localizedDescription
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
        store.entriesAsync(limit: 500) { [weak self] entries in
            guard let self else { return }
            self.history = entries
            self.pendingCount = entries.filter {
                $0.status == .unrecovered && ($0.audioPath?.isEmpty == false)
            }.count
        }
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

    /// Brings back the app that had focus when the recording started, so the
    /// text lands where the user was typing even if they switched windows
    /// during transcription.
    private func restoreTargetApplication() -> Bool {
        guard let target = targetApplication, !target.isTerminated else { return false }

        let current = NSWorkspace.shared.frontmostApplication
        if current?.processIdentifier == target.processIdentifier { return true }

        guard target.activate() else { return false }

        // Activation is asynchronous; give it a moment and verify instead of
        // trusting a fixed delay.
        for _ in 0..<12 {
            usleep(30_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                return true
            }
        }
        return false
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

    /// Recordings whose text never arrived, still on disk.
    @Published private(set) var pendingCount = 0

    /// Shown in the menu so the hotkey is discoverable without opening Settings.
    var hotkeyHint: String {
        guard !activeHotkey.isEmpty else {
            return "No free hotkey — open Settings and record another"
        }
        return settings.hotkeyMode == "hold"
            ? "Hold \(activeHotkey) to dictate"
            : "Press \(activeHotkey) to start and stop"
    }
}
