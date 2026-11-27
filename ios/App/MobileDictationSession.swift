import AVFoundation
import SwiftUI

@MainActor
final class MobileDictationSession: ObservableObject {
    static let shared = MobileDictationSession()
    static let duration = 15 * 60

    @Published private(set) var deadline: Date?
    @Published private(set) var working = false
    @Published private(set) var message: String?
    /// The latest finished dictation, for the first-run tour. / Останнє завершене диктування, для знайомства.
    @Published private(set) var delivery: DictationDelivery?

    private let audio = SessionAudio()
    private var session: UUID?
    private var currentRequest: UUID?
    private var phase: DictationBridge.Status.Phase = .ready
    private var text: String?
    private var warning: String?
    private var localNotice = LocalFallbackNotice()
    private var modelUnload: Task<Void, Never>?
    private var requestLayout: KeyboardLayout?
    private var requestSelection: String?
    private var phaseUntil = Date.distantFuture
    private var lastNonce: UUID?
    private var lastPublish = Date.distantPast
    private var timer: Task<Void, Never>?
    private var recognition: Task<Void, Never>?

    @discardableResult
    func enableConfigured() async -> Bool {
        if session != nil { return true }
        guard !working else { return false }
        working = true
        message = nil
        defer { working = false }
        do {
            guard MobileGateway.isProvisioned else { throw MobileDictationError.gatewayNotProvisioned }
            // Nothing leaves the device before the user has agreed. / До згоди користувача з пристрою нічого не йде.
            guard MobileConsent.isGiven else { throw MobileDictationError.consentRequired }
            guard await AVAudioApplication.requestRecordPermission() else {
                throw MobileDictationError.microphoneDenied
            }
            try audio.arm()
            session = UUID()
            deadline = Date().addingTimeInterval(TimeInterval(Self.duration))
            try publish()
            prewarmOnDeviceModelIfLikelyNeeded()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                    guard let self else { return }
                    await tick()
                }
            }
            return true
        } catch {
            end(message: error.localizedDescription)
            return false
        }
    }

    func end(message: String? = nil) {
        timer?.cancel()
        timer = nil
        recognition?.cancel()
        recognition = nil
        if session != nil || audio.isRunning { audio.disarm() }
        DictationBridge.clearStatus()
        deadline = nil
        session = nil
        lastNonce = nil
        setReady()
        self.message = message
    }

    private func setReady() {
        phase = .ready
        phaseUntil = .distantFuture
        currentRequest = nil
        requestLayout = nil
        requestSelection = nil
        text = nil
        warning = nil
        lastPublish = .distantPast
    }

    private func tick() async {
        guard let deadline, let session else { return }
        guard audio.isRunning else {
            end(message: String(localized: "The session ended. Start a new session to dictate."))
            return
        }
        if Date() >= deadline, phase == .ready {
            end(message: String(localized: "The session ended. Start a new session to dictate."))
            return
        }
        do {
            let command = try await Task.detached(priority: .userInitiated) { try DictationBridge.command() }.value
            guard !Task.isCancelled, self.session == session else { return }
            let now = Date()
            if let command, command.session == session,
               command.action != .start || now < deadline,
               command.nonce != lastNonce, abs(now.timeIntervalSince(command.time)) < 4 {
                lastNonce = command.nonce
                handle(command)
            }
            if now >= phaseUntil || (now >= deadline && phase == .recording) {
                switch phase {
                case .recording: finishRecording()
                case .result, .error: setReady()
                case .ready, .processing: break
                }
            }
            if now >= deadline, phase == .ready {
                end(message: String(localized: "The session ended. Start a new session to dictate."))
                return
            }
            if now.timeIntervalSince(lastPublish) >= 0.8 { try publish() }
        } catch {
            guard !Task.isCancelled, self.session == session else { return }
            end(message: error.localizedDescription)
        }
    }

    private func handle(_ command: DictationBridge.Command) {
        if command.action == .start, phase == .ready {
            currentRequest = command.request
            requestLayout = command.layout
            requestSelection = command.selection.flatMap { $0.isEmpty ? nil : $0 }
            if let requestSelection, SelectionEditLimits.isTooLong(requestSelection) {
                complete(request: command.request, phase: .error, text: DictationBridge.BridgeError.selectionTooLong.localizedDescription)
                return
            }
            audio.begin()
            phase = .recording
            phaseUntil = Date().addingTimeInterval(60)
            lastPublish = .distantPast
            return
        }
        guard currentRequest == command.request else { return }
        switch command.action {
        case .stop where phase == .recording:
            finishRecording()
        case .cancel:
            audio.cancel()
            recognition?.cancel()
            recognition = nil
            setReady()
        case .consume where phase == .result || phase == .error:
            setReady()
        default:
            break
        }
    }

    private func finishRecording() {
        guard let request = currentRequest else { return }
        let recording = audio.finish()
        // Do not let the idle timer drop the model in the middle of this dictation.
        // Не даємо таймеру простою вивантажити модель посеред цього диктування.
        modelUnload?.cancel()
        phase = .processing
        phaseUntil = .distantFuture
        lastPublish = .distantPast
        let layout = requestLayout
        let selection = requestSelection
        let locale = layout?.speechLocale ?? UserDefaults.standard.string(forKey: MobilePreferences.locale)
            ?? MobilePreferences.defaultLocale
        let language = LanguagePolicy.normalize(locale)
        let translatesToLayout = UserDefaults.standard.bool(forKey: MobilePreferences.translateToLayout)
        let target = translatesToLayout ? layout?.rawValue ?? language : nil
        let languageHint = target != nil || selection != nil ? nil : language
        recognition = Task {
            // The on-device model can only replace recognition; a later cloud step that fails
            // must not suggest downloading it.
            // Модель на пристрої замінює лише розпізнавання; збій пізнішого хмарного кроку
            // не має пропонувати її завантаження.
            var recognised = false
            do {
                let clip = try await Task.detached(priority: .userInitiated) {
                    try recording.makeClip()
                }.value
                defer { try? FileManager.default.removeItem(at: clip.url) }
                try Task.checkCancellation()
                // With translation on, the layout names the target, so the spoken language is unknown.
                // Коли ввімкнено переклад, розкладка задає цільову мову, тож мова мовлення невідома.
                let transcript = try await MobileRecognition.transcribe(clip, languageHint: languageHint,
                                                                        spokenLanguage: target == nil ? language : nil)
                recognised = true
                UserDefaults.standard.set(transcript.local != nil, forKey: MobilePreferences.lastDictationOnDevice)
                try Task.checkCancellation()
                // The notice counts as shown only when a result actually carries it.
                // Повідомлення вважається показаним лише тоді, коли результат справді його несе.
                let note = localNotice.pending(for: transcript.local)
                let shown: LocalFallback?? = .some(transcript.local)
                if transcript.local != nil {
                    scheduleModelUnload()
                    // On-device results skip every cloud text step.
                    // Результат із пристрою оминає всі хмарні кроки з текстом.
                    if selection != nil {
                        complete(request: request, phase: .error, text: LocalFallback.editsNeedCloud)
                    } else {
                        complete(request: request, phase: .result, text: transcript.text, warning: note, shown: shown,
                                 delivery: .init(text: transcript.text, raw: transcript.text, language: transcript.language))
                    }
                    return
                }
                let output = MobileTextOutput()
                if let selection {
                    let replacement = try await output.editSelection(
                        selection, instruction: transcript.text
                    )
                    complete(request: request, phase: .result, text: replacement, warning: note, shown: shown,
                             delivery: .init(text: replacement, raw: transcript.text, language: transcript.language, edited: true))
                    return
                }
                let result = await output.prepare(transcript, target: target)
                let source = TextLanguage.source(in: transcript.text, reported: transcript.language)
                complete(request: request, phase: .result, text: result.text,
                         warning: result.translationFailed ? String(localized: "Translation unavailable. The original dictation was inserted.") : note,
                         shown: result.translationFailed ? nil : shown,
                         delivery: .init(text: result.text, raw: transcript.text, language: transcript.language,
                                         translated: target != nil && source != target && !result.translationFailed))
            } catch {
                scheduleModelUnload()
                complete(request: request, phase: .error,
                         text: recognised ? error.localizedDescription
                             : MobileRecognition.failureMessage(for: error, spokenLanguage: target == nil ? language : nil))
            }
        }
    }

    /// The first load in a fresh process takes about 18 s on an iPhone 15 Pro (later reloads 0.3 s).
    /// Pay it when the session starts, if the device is offline or the last dictation already ran
    /// on the device, instead of inside the first dictation.
    /// Перше завантаження у свіжому процесі триває близько 18 с на iPhone 15 Pro (наступні — 0,3 с).
    /// Витрачаємо цей час на початку сесії, якщо пристрій без мережі або попереднє диктування вже
    /// йшло на пристрої, а не всередині першого диктування.
    private func prewarmOnDeviceModelIfLikelyNeeded() {
        guard ParakeetRecognizer.shared.isConfigured(),
              CloudAvailability.shared.blocked() != nil
                || UserDefaults.standard.bool(forKey: MobilePreferences.lastDictationOnDevice) else { return }
        Task {
            try? await ParakeetRecognizer.shared.warmUp()
            scheduleModelUnload()
        }
    }

    /// The on-device model holds about a gigabyte while loaded; free it after a quiet minute.
    /// Завантажена модель на пристрої тримає близько гігабайта; звільняємо її після хвилини тиші.
    private func scheduleModelUnload() {
        modelUnload?.cancel()
        modelUnload = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await ParakeetRecognizer.shared.unload()
        }
    }

    private func complete(request: UUID, phase: DictationBridge.Status.Phase, text: String, warning: String? = nil,
                          shown: LocalFallback?? = nil, delivery: DictationDelivery? = nil) {
        guard !Task.isCancelled, currentRequest == request else { return }
        if let delivery { self.delivery = delivery }
        if let shown { localNotice.shown(shown) }
        recognition = nil
        requestSelection = nil
        self.phase = phase
        self.text = text
        self.warning = warning
        phaseUntil = Date().addingTimeInterval(10)
        do { try publish() } catch { end(message: error.localizedDescription) }
    }

    private func publish() throws {
        guard let session, let deadline else { return }
        let now = Date()
        let heartbeat = now.addingTimeInterval(4)
        try DictationBridge.publish(.init(session: session, request: currentRequest, phase: phase,
                                           expires: phase == .ready ? min(deadline, heartbeat) : heartbeat,
                                           text: text, warning: warning, local: localNotice.isLocal ? true : nil))
        lastPublish = now
    }
}
