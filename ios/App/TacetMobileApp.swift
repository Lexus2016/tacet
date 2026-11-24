import AVFoundation
import SwiftUI

@main
struct TacetMobileApp: App {
    init() {
        MobilePreferences.migrateAudioConsent()
    }

    var body: some Scene {
        WindowGroup {
            SessionView()
        }
    }
}

private struct SessionView: View {
    @StateObject private var session = MobileDictationSession.shared
    @AppStorage(MobilePreferences.provider) private var engine = MobileRecognition.apple
    @AppStorage(MobilePreferences.recognitionModel) private var recognitionModel = ""
    @AppStorage(MobilePreferences.fallbackEnabled) private var fallbackEnabled = false
    @AppStorage(MobilePreferences.fallback) private var fallback = MobileRecognition.groq
    @AppStorage(MobilePreferences.fallbackRecognitionModel) private var fallbackRecognitionModel = ""
    @AppStorage(MobilePreferences.translateToLayout) private var translateToLayout = false
    @State private var openedFromKeyboard = false
    @State private var showingKeyboardLanguages = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Dictation session") {
                    if let deadline = session.deadline {
                        Label("Ready in the Tacet keyboard", systemImage: "mic.fill")
                            .foregroundStyle(.green)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Session time left: \(max(0, Int(deadline.timeIntervalSince(context.date)))) s")
                                .monospacedDigit()
                        }
                        if openedFromKeyboard {
                            Text("Tap the system back arrow. Recording starts when the same text field and Tacet keyboard reappear.")
                        } else {
                            Text("Open a text field and tap the microphone on the Tacet keyboard.")
                        }
                        Button("End session", role: .destructive) { session.end() }
                    } else {
                        Button {
                            Task { await session.enableConfigured() }
                        } label: {
                            if session.working {
                                Label("Preparing session…", systemImage: "hourglass")
                            } else {
                                Label("Enable dictation", systemImage: "mic")
                            }
                        }
                        .disabled(session.working)
                        Text("A session lasts 15 minutes. Tacet keeps audio only while you dictate.")
                    }
                    if let message = session.message {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Primary model", selection: $engine) {
                        ForEach(MobileRecognition.allCases) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    if engine == .openrouter {
                        MobileModelField(title: "Primary model ID", provider: .openrouter, model: $recognitionModel,
                                         placeholder: engine.defaultModelID, transcription: true)
                    }
                    Toggle("Use fallback model", isOn: $fallbackEnabled)
                    if fallbackEnabled {
                        Picker("Fallback model", selection: $fallback) {
                            ForEach(MobileRecognition.allCases) { option in
                                Text(option.name).tag(option)
                            }
                        }
                        if fallback == .openrouter {
                            MobileModelField(title: "Fallback model ID", provider: .openrouter, model: $fallbackRecognitionModel,
                                             placeholder: fallback.defaultModelID, transcription: true)
                        }
                        if MobileRecognition.Model(engine, modelID: recognitionModel)
                            == MobileRecognition.Model(fallback, modelID: fallbackRecognitionModel) {
                            Text("Choose a different model for the fallback.").foregroundStyle(.secondary)
                        }
                    }
                    if translateToLayout, engine == .apple && (!fallbackEnabled || fallback == .apple) {
                        Text("Choose an online recognition model for language detection.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recognition")
                } footer: {
                    Text(translateToLayout
                         ? "An online model detects the language you speak."
                         : "The active Tacet keyboard layout sets the language to listen for.")
                }
                .disabled(session.deadline != nil || session.working)

                MobileCleanupSettings()
                    .disabled(session.deadline != nil || session.working)

                Section {
                    ForEach(MobileCloudProvider.allCases) { provider in
                        MobileCloudKeyRows(provider: provider)
                    }
                } header: {
                    Text("Cloud providers")
                } footer: {
                    Text("API keys are stored in Keychain. Audio sharing is required for online recognition. OpenRouter routes requests to the selected model provider.")
                }
                .disabled(session.deadline != nil || session.working)

                Section("Keyboard setup") {
                    Button("Keyboard languages") { showingKeyboardLanguages = true }
                    Text("In iPhone Settings, go to General → Keyboard → Keyboards. Add Tacet and turn on Allow Full Access for dictation. Then use the globe key to switch to Tacet.")
                    Link("Open Tacet Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
                Section("Quick start") {
                    Text("You can assign “Enable Tacet dictation” to the iPhone Action Button in Settings.")
                }
            }
            .navigationTitle("Tacet")
            .navigationDestination(isPresented: $showingKeyboardLanguages) { KeyboardLanguagesView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { event in
            if session.deadline != nil,
               (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                session.end(message: String(localized: "Another app interrupted the microphone. Start a new session."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            if session.deadline != nil { session.end() }
        }
        .onOpenURL { url in
            guard DictationBridge.consumeWake(url) else { return }
            openedFromKeyboard = true
            showingKeyboardLanguages = false
            Task { await session.enableConfigured() }
        }
    }
}

private struct MobileCleanupSettings: View {
    @AppStorage(MobilePreferences.cleanupEnabled) private var enabled = false
    @AppStorage(MobilePreferences.translateToLayout) private var translateToLayout = false
    @AppStorage(MobilePreferences.cleanupProvider) private var provider = MobileCloudProvider.groq
    @AppStorage(MobilePreferences.cleanupModel) private var model = ""
    @AppStorage(MobilePreferences.cleanupFallbackEnabled) private var fallbackEnabled = false
    @AppStorage(MobilePreferences.cleanupFallbackProvider) private var fallbackProvider = MobileCloudProvider.groq
    @AppStorage(MobilePreferences.cleanupFallbackModel) private var fallbackModel = ""

    var body: some View {
        Section {
            Toggle("Send transcripts for correction", isOn: $enabled)
            Toggle("Translate to the keyboard language", isOn: $translateToLayout)
            if enabled || translateToLayout {
                modelRows("Primary", provider: $provider, model: $model, fallback: false)
                Toggle("Use fallback model", isOn: $fallbackEnabled)
                if fallbackEnabled {
                    modelRows("Fallback", provider: $fallbackProvider, model: $fallbackModel, fallback: true)
                    if provider == fallbackProvider, resolved(model, provider: provider, fallback: false)
                        == resolved(fallbackModel, provider: fallbackProvider, fallback: true) {
                        Text("Choose a different model or provider for the fallback.").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Text processing")
        } footer: {
            Text("Correction and translation send transcripts to the selected providers. For translation, Tacet uses the layout selected when you tap the microphone. If translation fails, Tacet inserts the original and shows a warning.")
        }
    }

    private func modelRows(_ title: LocalizedStringKey, provider: Binding<MobileCloudProvider>,
                           model: Binding<String>, fallback: Bool) -> some View {
        let selection = Binding(get: { provider.wrappedValue }, set: {
            guard $0 != provider.wrappedValue else { return }
            provider.wrappedValue = $0
            model.wrappedValue = ""
        })
        return Group {
            Picker(title, selection: selection) {
                ForEach(MobileCloudProvider.allCases) { option in
                    Text(option.name).tag(option)
                }
            }
            MobileModelField(title: fallback ? "Fallback model ID" : "Primary model ID",
                             provider: provider.wrappedValue, model: model,
                             placeholder: provider.wrappedValue.defaultChatModel(fallback: fallback))
        }
    }

    private func resolved(_ model: String, provider: MobileCloudProvider, fallback: Bool) -> String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultChatModel(fallback: fallback) : value
    }
}

private struct MobileModelField: View {
    let title: LocalizedStringKey
    let provider: MobileCloudProvider
    @Binding var model: String
    let placeholder: String
    var transcription = false
    @State private var browsing = false

    var body: some View {
        HStack(spacing: 14) {
            TextField(title, text: $model, prompt: Text(placeholder))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(title))
            Button {
                browsing = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Browse models")
        }
        .sheet(isPresented: $browsing) {
            MobileModelList(provider: provider, transcription: transcription, selection: $model)
        }
    }
}

private struct MobileModelList: View {
    let provider: MobileCloudProvider
    let transcription: Bool
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?
    @State private var request = 0

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView("Loading models…")
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Try again") { request += 1 }
                } else {
                    let filtered = query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
                    if filtered.isEmpty { Text("No matching models").foregroundStyle(.secondary) }
                    ForEach(filtered, id: \.self) { model in
                        Button(model) {
                            selection = model
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("\(provider.name) models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search models")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task(id: request) {
            loading = true
            failure = nil
            defer { loading = false }
            do {
                guard let spec = ProviderCatalog.spec(provider.rawValue) else { throw MobileDictationError.unavailable }
                models = try await ModelCatalog.fetch(spec: spec, baseURL: nil, transcription: transcription)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}

private struct MobileCloudKeyRows: View {
    let provider: MobileCloudProvider
    @AppStorage private var allowsAudio: Bool
    @State private var hasKey: Bool
    @State private var draft = ""
    @State private var failed = false

    init(provider: MobileCloudProvider) {
        self.provider = provider
        _allowsAudio = AppStorage(wrappedValue: false, provider.audioPreference)
        _hasKey = State(initialValue: provider.hasKey)
    }

    var body: some View {
        SecureField("\(provider.name) API key", text: $draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button("Save \(provider.name) key") {
            update(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if hasKey {
            Toggle("Allow sending audio to \(provider.name)", isOn: $allowsAudio)
            Button("Remove \(provider.name) key", role: .destructive) { update(nil) }
        }
        if failed { Text("The key could not be updated.").foregroundStyle(.red) }
    }

    private func update(_ value: String?) {
        failed = !Keychain.set(value, account: provider.rawValue)
        if !failed {
            hasKey = value != nil
            draft = ""
            if value == nil { allowsAudio = false }
        }
    }
}

private struct KeyboardLanguagesView: View {
    @State private var selection = KeyboardLayout.ordered((try? DictationBridge.keyboardLayouts()) ?? KeyboardLayout.defaults)
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(KeyboardLayout.allCases) { layout in
                    Toggle(layout.name, isOn: Binding(get: { selection.contains(layout) },
                                                     set: { enabled in update(layout, enabled: enabled) }))
                        .disabled(selection == [layout])
                }
            } footer: {
                Text("Choose the layouts you want on the Tacet keyboard. Keep at least one selected.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Keyboard languages")
    }

    private func update(_ layout: KeyboardLayout, enabled: Bool) {
        let proposed = enabled ? selection + [layout] : selection.filter { $0 != layout }
        guard !proposed.isEmpty else { return }
        do {
            try DictationBridge.setKeyboardLayouts(proposed)
            selection = KeyboardLayout.ordered(proposed)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
