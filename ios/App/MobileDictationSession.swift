import AVFoundation
import SwiftUI

@MainActor
final class MobileDictationSession: ObservableObject {
    static let shared = MobileDictationSession()
    static let duration = 15 * 60

    @Published private(set) var deadline: Date?
    @Published private(set) var working = false
    @Published private(set) var message: String?

    private let audio = SessionAudio()
    private var session: UUID?
    private var currentRequest: UUID?
    private var phase: DictationBridge.Status.Phase = .ready
    private var text: String?
    private var warning: String?
    private var requestLayout: KeyboardLayout?
    private var phaseUntil = Date.distantFuture
    private var lastNonce: UUID?
    private var lastPublish = Date.distantPast
    private var timer: Task<Void, Never>?
    private var recognition: Task<Void, Never>?
    private var primary = MobileRecognition.Model(.apple)
    private var fallback: MobileRecognition.Model?
    private var locale = "en-US"
    private var translatesToLayout = false

    @discardableResult
    func enableConfigured() async -> Bool {
        MobilePreferences.migrateAudioConsent()
        let defaults = UserDefaults.standard
        let engine = defaults.string(forKey: MobilePreferences.provider)
            .flatMap(MobileRecognition.init(rawValue:)) ?? .apple
        let fallbackEngine = defaults.string(forKey: MobilePreferences.fallback)
            .flatMap(MobileRecognition.init(rawValue:)) ?? .groq
        let primary = MobileRecognition.Model(engine, modelID: defaults.string(forKey: MobilePreferences.recognitionModel) ?? "")
        let fallback = MobileRecognition.Model(fallbackEngine,
            modelID: defaults.string(forKey: MobilePreferences.fallbackRecognitionModel) ?? "")
        let models = defaults.bool(forKey: MobilePreferences.fallbackEnabled) && primary != fallback
            ? [primary, fallback] : [primary]
        let locale = defaults.string(forKey: MobilePreferences.locale) ?? MobilePreferences.defaultLocale
        return await enable(models: models, locale: locale, translatesToLayout: defaults.bool(forKey: MobilePreferences.translateToLayout))
    }

    private func enable(models: [MobileRecognition.Model], locale: String, translatesToLayout: Bool) async -> Bool {
        if session != nil { return true }
        guard !working else { return false }
        working = true
        message = nil
        defer { working = false }
        do {
            let eligible = translatesToLayout ? models.filter { $0.engine.cloudProvider != nil } : models
            guard !eligible.isEmpty else { throw MobileDictationError.translationNeedsOnlineRecognition }
            if translatesToLayout {
                let models = textModels()
                guard models.primary?.isConfigured == true || models.fallback?.isConfigured == true else {
                    throw MobileDictationError.translationNeedsTextModel
                }
            }
            var ready: [MobileRecognition.Model] = []
            var preparationError: Error = MobileDictationError.unavailable
            for model in eligible {
                do {
                    try await model.engine.prepare()
                    ready.append(model)
                } catch {
                    preparationError = error
                }
            }
            guard let primary = ready.first else { throw preparationError }
            guard await AVAudioApplication.requestRecordPermission() else {
                throw MobileDictationError.microphoneDenied
            }
            try audio.arm()
            self.primary = primary
            fallback = ready.dropFirst().first
            self.locale = locale
            self.translatesToLayout = translatesToLayout
            session = UUID()
            deadline = Date().addingTimeInterval(TimeInterval(Self.duration))
            try publish()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                    guard let self else { return }
                    tick()
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
        text = nil
        warning = nil
        lastPublish = .distantPast
    }

    private func tick() {
        let now = Date()
        guard let deadline, let session, now < deadline, audio.isRunning else {
            end(message: String(localized: "The session ended. Start a new session to dictate."))
            return
        }
        do {
            if let command = try DictationBridge.command(), command.session == session,
               command.nonce != lastNonce, abs(now.timeIntervalSince(command.time)) < 4 {
                lastNonce = command.nonce
                handle(command)
            }
            if now >= phaseUntil {
                switch phase {
                case .recording: finishRecording()
                case .result, .error: setReady()
                case .ready, .processing: break
                }
            }
            if now.timeIntervalSince(lastPublish) >= 0.8 { try publish() }
        } catch {
            end(message: error.localizedDescription)
        }
    }

    private func handle(_ command: DictationBridge.Command) {
        if command.action == .start, phase == .ready {
            currentRequest = command.request
            requestLayout = command.layout
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
        phase = .processing
        phaseUntil = .distantFuture
        lastPublish = .distantPast
        let primary = self.primary
        let fallback = self.fallback
        let layout = requestLayout
        let locale = layout?.speechLocale ?? self.locale
        let languageHint = translatesToLayout ? nil : LanguagePolicy.normalize(locale)
        recognition = Task {
            do {
                let clip = try await Task.detached(priority: .userInitiated) {
                    try recording.makeClip()
                }.value
                defer { try? FileManager.default.removeItem(at: clip.url) }
                try Task.checkCancellation()
                let transcript = try await MobileRecognition.transcribe(primary: primary, fallback: fallback) {
                    try await $0.engine.transcribe(clip, locale: locale, languageHint: languageHint, modelID: $0.id)
                }
                try Task.checkCancellation()
                let models = textModels()
                let result = await MobileTextOutput().prepare(
                    transcript, target: translatesToLayout ? layout?.rawValue ?? LanguagePolicy.normalize(locale) : nil,
                    correct: UserDefaults.standard.bool(forKey: MobilePreferences.cleanupEnabled),
                    primary: models.primary, fallback: models.fallback
                )
                complete(request: request, phase: .result, text: result.text,
                         warning: result.translationFailed ? String(localized: "Translation unavailable. The original dictation was inserted.") : nil)
            } catch {
                complete(request: request, phase: .error, text: error.localizedDescription)
            }
        }
    }

    private func textModels() -> (primary: CleanupConfiguration?, fallback: CleanupConfiguration?) {
        let defaults = UserDefaults.standard
        func configuration(providerKey: String, modelKey: String, fallback: Bool) -> CleanupConfiguration? {
            let provider = defaults.string(forKey: providerKey).flatMap(MobileCloudProvider.init(rawValue:)) ?? .groq
            return provider.cleanup(model: defaults.string(forKey: modelKey) ?? "", fallback: fallback)
        }
        let primary = configuration(providerKey: MobilePreferences.cleanupProvider,
                                    modelKey: MobilePreferences.cleanupModel, fallback: false)
        let backup = defaults.bool(forKey: MobilePreferences.cleanupFallbackEnabled)
            ? configuration(providerKey: MobilePreferences.cleanupFallbackProvider,
                            modelKey: MobilePreferences.cleanupFallbackModel, fallback: true) : nil
        return (primary, backup)
    }

    private func complete(request: UUID, phase: DictationBridge.Status.Phase, text: String, warning: String? = nil) {
        guard !Task.isCancelled, currentRequest == request else { return }
        recognition = nil
        self.phase = phase
        self.text = text
        self.warning = warning
        phaseUntil = Date().addingTimeInterval(10)
        do { try publish() } catch { end(message: error.localizedDescription) }
    }

    private func publish() throws {
        guard let session, let deadline else { return }
        let now = Date()
        try DictationBridge.publish(.init(session: session, request: currentRequest, phase: phase,
                                           expires: min(deadline, now.addingTimeInterval(4)),
                                           text: text, warning: warning))
        lastPublish = now
    }
}
