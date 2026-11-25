import SwiftUI

enum MobileSettingsPage: Hashable {
    case recognition, textProcessing, providers, keyboard, keyboardLanguages
    case provider(MobileCloudProvider)

    static let menu: [Self] = [.recognition, .textProcessing, .providers, .keyboard]

    @ViewBuilder
    var menuLabel: some View {
        switch self {
        case .recognition:
            menuRow("Recognition", detail: "Choose which models turn speech into text.", icon: "waveform")
        case .textProcessing:
            menuRow("Text processing", detail: "Correct mistakes or translate to the keyboard language.", icon: "text.badge.checkmark")
        case .providers:
            menuRow("Cloud providers", detail: "Manage API keys and audio permissions.", icon: "cloud")
        case .keyboard:
            menuRow("Keyboard", detail: "Set up the Tacet keyboard and choose its languages.", icon: "keyboard")
        case .keyboardLanguages, .provider:
            EmptyView()
        }
    }

    private func menuRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    func destination(locked: Bool) -> some View {
        switch self {
        case .recognition:
            MobileRecognitionSettings(locked: locked)
        case .textProcessing:
            MobileCleanupSettings(locked: locked)
        case .providers:
            MobileProvidersSettings()
        case .provider(let provider):
            LockedSettingsForm(title: provider.name, locked: locked) {
                Section {
                    MobileCloudKeyRows(provider: provider)
                } footer: {
                    Text("Keys stay in Keychain. Enable audio sharing here only if you want this provider to recognize speech.")
                    if provider == .openrouter {
                        Text("OpenRouter routes requests to the selected model provider.")
                    }
                }
            }
        case .keyboard:
            MobileKeyboardSettings()
        case .keyboardLanguages:
            KeyboardLanguagesView()
        }
    }
}

private struct LockedSettingsForm<Content: View>: View {
    let title: String
    let locked: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            if locked {
                Label("End the dictation session to edit these settings.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            content().disabled(locked)
        }
        .navigationTitle(title)
    }
}

private struct MobileRecognitionSettings: View {
    let locked: Bool
    @AppStorage(MobilePreferences.provider) private var engine = MobileRecognition.apple
    @AppStorage(MobilePreferences.recognitionModel) private var recognitionModel = ""
    @AppStorage(MobilePreferences.fallbackEnabled) private var fallbackEnabled = false
    @AppStorage(MobilePreferences.fallback) private var fallback = MobileRecognition.groq
    @AppStorage(MobilePreferences.fallbackRecognitionModel) private var fallbackRecognitionModel = ""
    @AppStorage(MobilePreferences.translateToLayout) private var translateToLayout = false

    var body: some View {
        LockedSettingsForm(title: String(localized: "Recognition"), locked: locked) {
            Section {
                modelRow(selection: $engine, model: $recognitionModel, title: "Primary model ID")
            } header: {
                Text("Primary model")
            } footer: {
                Text(translateToLayout
                     ? "An online model detects the language you speak."
                     : "The active Tacet keyboard layout sets the language to listen for.")
                if translateToLayout, engine == .apple && (!fallbackEnabled || fallback == .apple) {
                    Text("Choose an online recognition model for language detection.")
                }
            }
            Section {
                Toggle("Use fallback model", isOn: $fallbackEnabled)
                if fallbackEnabled {
                    modelRow(selection: $fallback, model: $fallbackRecognitionModel, title: "Fallback model ID")
                    if MobileRecognition.Model(engine, modelID: recognitionModel)
                        == MobileRecognition.Model(fallback, modelID: fallbackRecognitionModel) {
                        Text("Choose a different model for the fallback.").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Fallback model")
            } footer: {
                Text("Used when the primary model fails.")
            }
        }
    }

    private func modelRow(selection: Binding<MobileRecognition>, model: Binding<String>,
                          title: LocalizedStringKey) -> some View {
        Group {
            Picker("Model", selection: selection) {
                ForEach(MobileRecognition.allCases) { option in
                    Text(option.name).tag(option)
                }
            }
            if selection.wrappedValue == .openrouter {
                MobileModelField(title: title, provider: .openrouter, model: model,
                                 placeholder: selection.wrappedValue.defaultModelID, transcription: true)
            }
        }
    }
}

private struct MobileCleanupSettings: View {
    let locked: Bool
    @AppStorage(MobilePreferences.cleanupEnabled) private var enabled = false
    @AppStorage(MobilePreferences.selectionEditing) private var selectionEditing = true
    @AppStorage(MobilePreferences.translateToLayout) private var translateToLayout = false
    @AppStorage(MobilePreferences.cleanupProvider) private var provider = MobileCloudProvider.groq
    @AppStorage(MobilePreferences.cleanupModel) private var model = ""
    @AppStorage(MobilePreferences.cleanupFallbackEnabled) private var fallbackEnabled = false
    @AppStorage(MobilePreferences.cleanupFallbackProvider) private var fallbackProvider = MobileCloudProvider.groq
    @AppStorage(MobilePreferences.cleanupFallbackModel) private var fallbackModel = ""

    var body: some View {
        LockedSettingsForm(title: String(localized: "Text processing"), locked: locked) {
            Section {
                Toggle("Correct dictation", isOn: $enabled)
                Toggle("Translate to the keyboard language", isOn: $translateToLayout)
                Toggle("Edit selected text with voice", isOn: $selectionEditing)
            } footer: {
                Text("Editing sends the selected text and your spoken instruction to the chosen text model. If the command fails, Tacet keeps the selection.")
            }
            if enabled || translateToLayout || selectionEditing {
                Section("Primary model") {
                    modelRows(provider: $provider, model: $model, fallback: false)
                }
                Section {
                    Toggle("Use fallback model", isOn: $fallbackEnabled)
                    if fallbackEnabled {
                        modelRows(provider: $fallbackProvider, model: $fallbackModel, fallback: true)
                        if provider == fallbackProvider, resolved(model, provider: provider, fallback: false)
                            == resolved(fallbackModel, provider: fallbackProvider, fallback: true) {
                            Text("Choose a different model or provider for the fallback.").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Fallback model")
                } footer: {
                    Text("Used when the primary model fails.")
                }
            }
        }
    }

    private func modelRows(provider: Binding<MobileCloudProvider>,
                           model: Binding<String>, fallback: Bool) -> some View {
        let selection = Binding(get: { provider.wrappedValue }, set: {
            guard $0 != provider.wrappedValue else { return }
            provider.wrappedValue = $0
            model.wrappedValue = ""
        })
        return Group {
            Picker("Provider", selection: selection) {
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

private struct MobileProvidersSettings: View {
    @State private var savedKeys: Set<MobileCloudProvider> = []

    var body: some View {
        Form {
            Section {
                ForEach(MobileCloudProvider.allCases) { provider in
                    NavigationLink(value: MobileSettingsPage.provider(provider)) {
                        HStack {
                            Text(provider.name)
                            Spacer(minLength: 12)
                            Text(savedKeys.contains(provider) ? "Key saved" : "No key")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Open a provider to add a key or change its audio permission.")
            }
        }
        .navigationTitle("Cloud providers")
        .onAppear { savedKeys = Set(MobileCloudProvider.allCases.filter(\.hasKey)) }
    }
}

private struct MobileKeyboardSettings: View {
    var body: some View {
        Form {
            Section {
                NavigationLink("Keyboard languages", value: MobileSettingsPage.keyboardLanguages)
            } footer: {
                Text("The layout sets the language for direct dictation. With translation enabled, it sets the language of the result.")
            }
            Section("Keyboard access") {
                Text("In iPhone Settings, go to General → Keyboard → Keyboards. Add Tacet and turn on Allow Full Access for dictation. Then use the globe key to switch to Tacet.")
                Link("Open Tacet Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
            Section("Quick start") {
                Text("You can assign “Enable Tacet dictation” to the iPhone Action Button in Settings.")
            }
        }
        .navigationTitle("Keyboard")
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
