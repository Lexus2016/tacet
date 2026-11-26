import AVFoundation
import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case processing
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            if oldValue == .recording, phase != .recording {
                backgroundAudio.end()
            }
        }
    }
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var hotkeyConflict = false
    @Published private(set) var pasteHotkeyAvailable = false
    @Published private(set) var statusNote: String = "Ready"
    @Published private(set) var lastFailure: String?

    private let settings = AppSettings.shared
    private let store = HistoryStore.shared
    private let capture = AudioCaptureService()
    private let backgroundAudio = BackgroundAudioDucker()
    private let pipeline = TranscriptionPipeline()
    private let cleanupPipeline = CleanupPipeline()
    private let translator = Translator()
    private var localNotice = LocalFallbackNotice()
    private let selectionEditor = SelectionEditor()
    private let hotkey = HotkeyManager()
    private let pasteHotkey = HotkeyManager(identifier: 2)
    private var pastingLast = false
    private let languageMemory = LanguageMemory()

    private var isStarting = false
    private var isRecordingHotkey = false
    private var updateRestart = UpdateRestartGate()
    private var noteTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var capturedSelection: SelectionReader.Selection = .none
    /// The key was released while the microphone was still starting.
    private var stopRequested = false
    private var didOpenMicrophoneSettings = false
    /// The combination actually registered, which may differ from the stored
    /// one when another app owns it. Formatted for display.
    private(set) var activeHotkey: String = ""
    private var targetFocus: SelectionReader.Focus?

    private init() {
        capture.levelHandler = { [weak self] level in
            DispatchQueue.main.async {
                guard let self, self.phase == .recording, self.settings.showHUD else { return }
                HUDController.shared.updateLevel(level)
            }
        }
        capture.configurationChangeHandler = { [weak self] in
            self?.status(String(localized: "Input device changed, stopping"))
            self?.stopRecording()
        }
        configureHotkey()
        refreshHistory()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    func recoverAtLaunch() {
        purgeAudio()
        adoptOrphanRecordings()
        recoverPendingRecordings()
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
        guard settings.hostedGatewayEnabled else { return }
        let pending = store.entries(limit: 100).filter {
            $0.status == .unrecovered && ($0.audioPath?.isEmpty == false)
        }
        guard !pending.isEmpty else { return }

        recoveryTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            for entry in pending {
                guard !Task.isCancelled,
                      phase == .idle,
                      settings.hostedGatewayEnabled,
                      !updateRestart.isRestarting,
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
                              autoRetry: false,
                              inBackground: true)
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

    func setHotkeyRecording(_ recording: Bool) {
        isRecordingHotkey = recording
        if recording {
            hotkey.unregister()
            pasteHotkey.unregister()
        } else {
            configureHotkey()
        }
    }

    func configureHotkey() {
        guard !isRecordingHotkey else { return }
        pasteHotkey.unregister()
        defer {
            pasteHotkey.onPress = { [weak self] in self?.pasteLast() }
            pasteHotkeyAvailable = pasteHotkey.register(keyCode: UInt32(kVK_ANSI_V),
                                                       modifiers: UInt32(controlKey | optionKey | cmdKey))
        }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onCancel = { [weak self] in self?.cancelModifierPress() }
        hotkey.togglesOnModifierRelease = { [weak self] in self?.settings.hotkeyMode == "toggle" }

        // A single modifier is monitored through flagsChanged.
        // Окрему клавішу-модифікатор відстежуємо через flagsChanged.
        if isModifierOnlyHotkey {
            let flags = HotkeyFormat.eventFlags(from: settings.hotkeyModifiers)
            if hotkey.registerModifierOnly(flags, keyCode: settings.hotkeyKeyCode) {
                activeHotkey = HotkeyFormat.title(keyCode: settings.hotkeyKeyCode,
                                                  modifiers: settings.hotkeyModifiers,
                                                  label: "")
                hotkeyConflict = false
                status(hotkeyHint)
            } else {
                activeHotkey = ""
                hotkeyConflict = true
                status("Modifier-only hotkey needs Accessibility permission")
            }
            return
        }

        let preferred = HotkeyFormat.title(keyCode: settings.hotkeyKeyCode,
                                           modifiers: settings.hotkeyModifiers,
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
        guard !isRecordingHotkey, phase != .processing else { return }

        if settings.hotkeyMode == "hold" {
            if phase == .idle { startRecording() }
        } else {
            toggle()
        }
    }

    private func hotkeyReleased() {

        guard settings.hotkeyMode == "hold" else { return }

        if phase == .preparing {
            stopRequested = true
            return
        }
        guard phase == .recording else { return }
        stopRecording()
    }

    /// The modifier was only part of a shortcut (Command-C): throw the empty
    /// recording away without a sound or a message.
    private func cancelModifierPress() {
        if phase == .preparing {
            stopRequested = true
            return
        }
        guard phase == .recording else { return }
        backgroundAudio.end()
        capture.cancel()
        phase = .idle
        status(String(localized: "Ready"))
        HUDController.shared.hide()
    }

    func toggle() {
        if phase == .recording {
            stopRecording()
        } else if phase == .preparing {
            stopRequested = true
        } else if phase == .idle {
            startRecording()
        }
    }

    // MARK: Recording

    func startRecording() {
        guard phase == .idle, !isStarting, !updateRestart.isRestarting else { return }
        if let issue = settings.gatewayActivationIssue {
            lastFailure = issue
            status(issue)
            if settings.showHUD { HUDController.shared.finish(error: issue) }
            AppWindows.shared.showSettings()
            return
        }
        isStarting = true
        stopRequested = false
        let startingApp = NSWorkspace.shared.frontmostApplication
        targetFocus = nil
        capturedSelection = .none

        // The indicator appears immediately; the engine is still starting.
        phase = .preparing
        if settings.showHUD { HUDController.shared.showPreparing() }

        // The microphone always wins over background recovery and model
        // housekeeping.
        recoveryTask?.cancel()
        recoveryTask = nil
        retryTask?.cancel()
        retryTask = nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        Task {
            defer { isStarting = false }

            guard await ensureMicrophone() else {
                handleBlockedMicrophone()
                return
            }

            if stopRequested {
                stopRequested = false
                phase = .idle
                HUDController.shared.hide()
                return
            }

            do {
                targetFocus = startingApp.flatMap { SelectionReader.Focus(for: $0) }
                if settings.selectionEditing, TextInserter.isAccessibilityTrusted(), let targetFocus {
                    capturedSelection = await SelectionReader.read(in: targetFocus)
                }

                if stopRequested {
                    stopRequested = false
                    phase = .idle
                    HUDController.shared.hide()
                    return
                }

                try capture.start()
                if settings.quietBackgroundAudio { backgroundAudio.begin() }
                phase = .recording
                lastFailure = nil
                status(String(localized: "Recording…"))
                if settings.playSounds { SoundService.shared.play(.start, style: settings.soundStyle) }
                if settings.showHUD { HUDController.shared.showRecording() }

            } catch {
                phase = .idle
                lastFailure = error.localizedDescription
                status(error.localizedDescription)
                HUDController.shared.finish(error: settings.showHUD ? error.localizedDescription : nil)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        backgroundAudio.end()

        let result: AudioCaptureService.Result
        do {
            guard let captured = try capture.stop() else {
                phase = .idle
                status(String(localized: "Ready"))
                HUDController.shared.hide()
                return
            }
            result = captured
        } catch {
            phase = .idle
            lastFailure = error.localizedDescription
            status(error.localizedDescription)
            HUDController.shared.hide()
            return
        }

        phase = .processing
        status(String(localized: "Transcribing…"))
        if settings.showHUD { HUDController.shared.showProcessing() }

        let clip = AudioClip(url: result.url, duration: result.duration, samples: result.samples)

        // Digital silence means the system is blocking the microphone: the
        // engine runs and delivers zeros, so "no speech" would be a lie.
        if result.peak == 0, result.rms == 0 {
            phase = .idle
            AudioStore.delete(path: result.url.path)
            handleBlockedMicrophone()
            return
        }

        if clip.duration < 0.25 {
            phase = .idle
            AudioStore.delete(path: result.url.path)
            status(String(localized: "No speech detected"))
            HUDController.shared.hide()
            return
        }

        if result.rms < 0.0016, result.peak < 0.01 {
            phase = .idle
            AudioStore.delete(path: result.url.path)
            status(String(localized: "No speech detected"))
            HUDController.shared.hide()
            return
        }

        Task { await process(clip: clip,
                             existingEntryID: nil,
                             allowPaste: true,
                             allowClipboard: true,
                             autoRetry: true,
                             focus: targetFocus,
                             selection: capturedSelection) }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        backgroundAudio.end()
        capture.cancel()
        phase = .idle
        status(String(localized: "Cancelled"))
        HUDController.shared.hide()
    }

    func interruptRecording() {
        if phase == .preparing { stopRequested = true }
        cancelRecording()
    }

    // MARK: Processing

    private func process(clip: AudioClip,
                         existingEntryID: String?,
                         allowPaste: Bool,
                         allowClipboard: Bool,
                         autoRetry: Bool,
                         inBackground: Bool = false,
                         focus: SelectionReader.Focus? = nil,
                         selection: SelectionReader.Selection = .none) async {
        updateRestart.activeTranscriptions += 1
        defer { updateRestart.activeTranscriptions -= 1 }
        let started = Date()
        let appName = focus?.application.localizedName

        if let issue = settings.gatewayActivationIssue {
            recordFailure(PipelineFailure(attempts: [Attempt(engine: EngineID.hostedGateway, error: issue, latency: 0)]),
                          clip: clip, latency: 0, appName: appName, existingEntryID: existingEntryID,
                          autoRetry: false, inBackground: inBackground)
            return
        }

        let engineConfiguration = settings.engineConfiguration
        let expectedLanguage: String? = focus?.application.bundleIdentifier
            .flatMap { languageMemory.language(for: $0) }

        let pipelineSettings = PipelineSettings(
            languageOverride: settings.languageOverride,
            engineOrder: settings.activeEngineOrder,
            dualLanguageCheck: settings.dualLanguageCheck,
            cloudTimeout: settings.cloudTimeout,
            expectedLanguage: expectedLanguage
        )

        let result = await pipeline.transcribe(clip, settings: pipelineSettings, engines: engineConfiguration)
        guard !Task.isCancelled else { return }

        switch result {
        case .success(let output):
            var text = output.transcript.text
            let sourceLanguage = TextLanguage.source(in: text, reported: output.transcript.language)
            var cleanupEngine: String?
            var notes: [String] = []
            // On-device results skip every cloud text step and say why, once per switch.
            // Результат із пристрою оминає всі хмарні кроки з текстом і раз на перехід пояснює чому.
            let local = output.localFallback
            let notice = localNotice.pending(for: local).map { (text: $0, fallback: local) }

            if output.partial {
                let completed = output.totalParts - output.failedParts
                let note = String(localized: "Only \(completed) of \(output.totalParts) parts were transcribed. The partial text is in History.")
                await deliver(text: text, raw: text, transcript: output.transcript, clip: clip,
                              latency: Date().timeIntervalSince(started), appName: appName,
                              cleanupEngine: nil, existingEntryID: existingEntryID, allowPaste: false,
                              allowClipboard: false, inBackground: inBackground, focus: focus,
                              note: (notes + [note]).joined(separator: "; "), partial: true, notice: notice)
                return
            }

            let configuration = settings.cleanupConfiguration

            let editingSelection = allowPaste && settings.selectionEditing && selection != .none
            if local == nil, !editingSelection, settings.isCleanupConfigured,
               text.split(whereSeparator: \.isWhitespace).count >= 3 {
                let cleaned = await cleanupPipeline.clean(text, sourceLanguage: sourceLanguage, configuration: configuration)
                guard !Task.isCancelled else { return }
                if cleaned.changed {
                    text = cleaned.text
                    cleanupEngine = cleaned.engine
                }
            }

            // Translation runs after cleanup: the model gets clean text and the
            // transcript keeps its original wording in History.
            if local == nil, !editingSelection, settings.hostedGatewayEnabled, settings.outputLanguage != "auto" {
                if sourceLanguage != settings.outputLanguage {
                    let outcome = await translator.translate(text,
                                                              to: settings.outputLanguage,
                                                              configuration: configuration, sourceLanguage: sourceLanguage)
                    if outcome.translated {
                        text = outcome.text
                    } else {
                        notes.append(String(localized: "Translation unavailable. The original dictation was inserted."))
                    }
                }
            }

            guard !Task.isCancelled else { return }

            if allowPaste, settings.selectionEditing {
                switch selection {
                case .text where local != nil:
                    notes.append(LocalFallback.editsNeedCloud)
                case .text(let selectedText, _) where SelectionEditLimits.isTooLong(selectedText):
                    // Refused here, before anything is sent. / Відмовляємо тут, до будь-якого надсилання.
                    notes.append(SelectionEditLimits.tooLongMessage)
                case .text(let selectedText, _):
                    do {
                        if settings.hostedGatewayEnabled,
                           let outcome = try await selectionEditor.edit(selection: selectedText,
                                                                instruction: text,
                                                                configuration: configuration) {
                            guard !Task.isCancelled else { return }
                            await applySelectionEdit(outcome.text,
                                                 instruction: text,
                                                 selection: selection,
                                                 focus: focus,
                                                 transcript: output.transcript,
                                                 clip: clip,
                                                 latency: Date().timeIntervalSince(started),
                                                 appName: appName,
                                                 cleanupEngine: cleanupEngine,
                                                 note: notes.isEmpty ? nil : notes.joined(separator: "; "))
                            return
                        }
                        notes.append(String(localized: "Selection edit failed. The instruction is in History."))
                    } catch {
                        notes.append(error.localizedDescription)
                    }
                    guard !Task.isCancelled else { return }
                case .unreadable:
                    notes.append(String(localized: "Selection could not be read. Text saved in History."))
                case .none:
                    break
                }
            }

            let selectionAllowsPaste = !settings.selectionEditing || selection == .none
            await deliver(text: text,
                          raw: output.transcript.text,
                          transcript: output.transcript,
                          clip: clip,
                          latency: Date().timeIntervalSince(started),
                          appName: appName,
                          cleanupEngine: cleanupEngine,
                          existingEntryID: existingEntryID,
                          allowPaste: allowPaste && selectionAllowsPaste,
                          allowClipboard: allowClipboard && selectionAllowsPaste,
                          inBackground: inBackground,
                          focus: focus,
                          note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                          notice: notice)

        case .failure(let failure):
            recordFailure(failure,
                          clip: clip,
                          latency: Date().timeIntervalSince(started),
                          appName: appName,
                          existingEntryID: existingEntryID,
                          autoRetry: autoRetry,
                          inBackground: inBackground)
        }
    }

    /// Replaces the selection with the result of the spoken instruction. An
    /// empty result removes the selection.
    private func applySelectionEdit(_ replacement: String,
                                    instruction: String,
                                    selection: SelectionReader.Selection,
                                    focus: SelectionReader.Focus?,
                                    transcript: Transcript,
                                    clip: AudioClip,
                                    latency: TimeInterval,
                                    appName: String?,
                                    cleanupEngine: String?,
                                    note: String?) async {
        var pasted = false
        var copied = false
        if settings.pasteAutomatically {
            if let focus, await SelectionReader.read(in: focus) == selection, focus.isCurrent {
                if replacement.isEmpty {
                    pasted = TextInserter.sendKey(0x33, to: focus.application)
                } else {
                    pasted = await TextInserter.paste(replacement, in: focus)
                }
            }
        } else if !replacement.isEmpty {
            copied = TextInserter.copy(replacement)
        }

        let finalNote = pasted || copied ? note : [
            note,
            String(localized: "Selection left unchanged. Result kept in History.")
        ].compactMap { $0 }.joined(separator: "; ")
        let displayed = replacement.isEmpty && pasted ? "(selection removed)" : replacement
        let entry = store.insert(text: displayed,
                                 rawText: instruction,
                                 engine: transcript.engine,
                                 language: transcript.language,
                                 duration: clip.duration,
                                 latency: latency,
                                 appName: appName,
                                 audioPath: clip.url.path,
                                 status: .ok,
                                 cleanupEngine: cleanupEngine,
                                 error: finalNote)

        let message: String
        if pasted {
            store.markInserted(id: entry.id)
            message = replacement.isEmpty ? String(localized: "Selection removed") : String(localized: "Selection replaced")
        } else if copied {
            message = String(localized: "Copied, selection untouched")
        } else {
            message = String(localized: "Selection left unchanged. Result kept in History.")
        }
        status(message)
        HUDController.shared.finish(error: settings.showHUD && !pasted && !copied ? message : nil)

        if settings.playSounds {
            SoundService.shared.play(pasted ? .success : .error, style: settings.soundStyle)
        }

        phase = .idle
        lastFailure = nil
        refreshHistory()
        scheduleIdleUnload()
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
                         inBackground: Bool,
                         focus: SelectionReader.Focus?,
                         note: String?,
                         partial: Bool = false,
                         notice: (text: String, fallback: LocalFallback?)? = nil) async {
        // A background attempt must not revive a deleted history entry.
        // Фоновий повтор не має відновлювати видалений запис історії.
        if let existingEntryID, store.entry(id: existingEntryID) == nil {
            if !inBackground {
                phase = .idle
                HUDController.shared.hide()
            }
            return
        }

        var pasted = false
        var copied = false
        var deliveryNote = note
        if allowClipboard, !allowPaste || !settings.pasteAutomatically {
            copied = TextInserter.copy(text)
        } else if allowPaste, let focus, focus.application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  focus.isCurrent, TextInserter.isAccessibilityTrusted() {
            let currentSelection = settings.selectionEditing ? await SelectionReader.read(in: focus) : .none
            if currentSelection == .none {
                pasted = await TextInserter.paste(text, in: focus)
            }
        }

        if allowPaste, settings.pasteAutomatically, !pasted {
            deliveryNote = [
                note,
                String(localized: "Could not insert safely. Text saved in History.")
            ].compactMap { $0 }.joined(separator: "; ")
        }

        if let bundleID = focus?.application.bundleIdentifier, let language = transcript.language {
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
                         error: deliveryNote)
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
                                     error: deliveryNote)
            entryID = entry.id
        }

        if pasted { store.markInserted(id: entryID) }
        refreshHistory()
        guard !inBackground else {
            if phase == .idle { scheduleIdleUnload() }
            return
        }

        let message: String
        if pasted {
            message = String(localized: "Inserted")
        } else if copied {
            message = String(localized: "Copied to clipboard, press ⌘V")
        } else if let deliveryNote {
            message = deliveryNote
        } else {
            message = String(localized: "Recovered — open History to copy")
        }
        let failedToDeliver = partial || (!pasted && !copied && (allowPaste || focus != nil))
        if let notice, !failedToDeliver {
            // The text arrived; say which mode produced it. The notice counts as shown only here,
            // so a failed or background delivery leaves it for the next dictation.
            // Текст доставлено; кажемо, який режим його дав. Повідомлення вважається показаним
            // лише тут, тож невдала чи фонова доставка лишає його наступному диктуванню.
            status(notice.text)
            if settings.showHUD { HUDController.shared.finish(notice: notice.text) } else { HUDController.shared.hide() }
            localNotice.shown(notice.fallback)
        } else {
            status(message)
            HUDController.shared.finish(error: settings.showHUD && failedToDeliver ? message : nil)
        }

        phase = .idle
        lastFailure = nil
        scheduleIdleUnload()
        if settings.playSounds { SoundService.shared.play(failedToDeliver ? .error : .success, style: settings.soundStyle) }
    }

    private func recordFailure(_ failure: PipelineFailure,
                               clip: AudioClip,
                               latency: TimeInterval,
                               appName: String?,
                               existingEntryID: String?,
                               autoRetry: Bool,
                               inBackground: Bool) {
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

        refreshHistory()
        guard !inBackground else {
            if phase == .idle { scheduleIdleUnload() }
            return
        }

        phase = .idle
        lastFailure = message
        status(String(localized: "Failed: \(message)"))
        let alert: String
        if let reason = failure.attempts.cloudFailure,
           !ParakeetRecognizer.shared.isConfigured(for: settings.languageOverride),
           settings.languageOverride.map(ParakeetRecognizer.supports) != false {
            alert = reason.downloadHint
        } else if failure.audioQuotaExhausted {
            alert = String(localized: "Dictation limit reached. See Plan and usage.")
        } else {
            alert = String(localized: "Not transcribed, recording kept")
        }
        HUDController.shared.finish(error: settings.showHUD ? alert : nil)
        if settings.playSounds { SoundService.shared.play(.error, style: settings.soundStyle) }
        if autoRetry, !failure.audioQuotaExhausted, let failedID {
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
            guard !Task.isCancelled, let self, self.phase == .idle,
                  !self.updateRestart.isRestarting else { return }
            await self.process(clip: clip,
                               existingEntryID: entryID,
                               allowPaste: false,
                               allowClipboard: false,
                               autoRetry: false,
                               inBackground: true)
        }
    }

    // MARK: History actions

    static let pasteShortcut = "⌃⌥⌘V"

    func pasteLast() {
        guard phase == .idle, !pastingLast, !updateRestart.isRestarting else { return }
        guard let last = store.last() else {
            status(String(localized: "No dictation to paste yet"))
            return
        }
        guard TextInserter.isAccessibilityTrusted() else {
            status(String(localized: "Enable Accessibility in Settings to paste the last dictation"))
            return
        }
        guard let focus = SelectionReader.Focus(),
              focus.application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              focus.element != nil else {
            status(String(localized: "Focus a text field to paste the last dictation"))
            return
        }
        pastingLast = true
        Task {
            defer { pastingLast = false }
            if !(await TextInserter.paste(last.text, in: focus)) {
                status(String(localized: "Could not paste the last dictation"))
            }
        }
    }

    func copyLast() {
        guard let last = store.last(), !last.text.isEmpty else {
            status("Nothing to copy yet")
            return
        }
        TextInserter.copy(last.text)
        status("Last dictation copied")
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
        guard phase == .idle, !isStarting, !updateRestart.isRestarting else { return }

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

    func reserveUpdateRestart() -> Bool {
        updateRestart.reserve(isIdle: phase == .idle && !isStarting && !pastingLast)
    }

    func releaseUpdateRestart() {
        updateRestart.release()
    }

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

    /// The microphone is silent at the system level: say so and open the pane
    /// that fixes it, instead of reporting "no speech".
    private func handleBlockedMicrophone() {
        phase = .idle
        lastFailure = "Microphone is blocked"
        status(String(localized: "Microphone is blocked — allow Tacet in System Settings"))
        HUDController.shared.finish(error: settings.showHUD ? String(localized: "Microphone blocked") : nil)
        if settings.playSounds {
            SoundService.shared.play(.error, style: settings.soundStyle)
        }
        guard !didOpenMicrophoneSettings else { return }
        didOpenMicrophoneSettings = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
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

    var menuBarMark: MenuBarMark {
        switch phase {
        case .preparing: return .preparing
        case .recording: return .recording
        case .processing: return .processing
        case .idle: return lastFailure == nil ? .ready : .attention
        }
    }

    /// Recordings whose text never arrived, still on disk.
    @Published private(set) var pendingCount = 0

    /// A lone modifier, optionally a specific side of it.
    private var isModifierOnlyHotkey: Bool {
        guard HotkeyFormat.singleModifier(settings.hotkeyModifiers) != nil else { return false }
        return settings.hotkeyKeyCode == 0 || HotkeyFormat.isModifierKeyCode(settings.hotkeyKeyCode)
    }

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
