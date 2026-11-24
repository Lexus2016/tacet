import SwiftUI

struct ProvidersSettingsView: View {
    @ObservedObject private var custom = CustomProviderStore.shared
    @ObservedObject private var health = ProviderHealth.shared
    @State private var presentedSheet: ProviderSheet?

    private enum ProviderSheet: Identifiable {
        case add, configure(String)

        var id: String {
            switch self {
            case .add: "add"
            case .configure(let provider): provider
            }
        }
    }

    private var providerIDs: [String] {
        var seen = Set<String>()
        let ordered = health.targets.map(\.id.provider) +
            ProviderCatalog.all.map(\.id) + [EngineID.parakeet]
        return ordered.filter { seen.insert($0).inserted }
    }

    var body: some View {
        SoftCard(title: "Provider overview", systemImage: "network") {
            actions
            ForEach(providerIDs, id: \.self) { provider in
                SoftDivider()
                providerRow(provider)
            }
        }
        .onAppear { health.refresh(configurationOnly: true) }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .add:
                AddProviderSheet()
            case .configure(let provider):
                ProviderConfigurationSheet(providerID: provider)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    health.refresh()
                } label: {
                    PendingActionLabel(title: "Check now", pendingTitle: "Checking providers…",
                                       isPending: health.isChecking)
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(health.isChecking || health.targets.isEmpty)

                Button {
                    presentedSheet = .add
                } label: {
                    Label("Add provider…", systemImage: "plus")
                }
                .buttonStyle(SoftButtonStyle())
            }
            if let finished = health.lastCheck {
                Text("Last checked at \(finished, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connections are checked every minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func providerRow(_ provider: String) -> some View {
        let targets = health.targets.filter { $0.id.provider == provider }
        let isLocal = provider == EngineID.parakeet
        let name = isLocal ? String(localized: "Parakeet (local)") :
            (ProviderCatalog.spec(provider)?.name ?? EngineID.displayName(provider))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Configure") { presentedSheet = .configure(provider) }
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityLabel(Text("Configure \(name)"))
            }

            if targets.isEmpty {
                Text(isLocal ? "Model not downloaded" : "Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(targets) { target in
                let condition = health.condition(for: target.id)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(target.active ? target.id.capability.title : String(localized: "Connected · inactive"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    ProviderStatusLabel(condition: condition)
                }
                if let reason = condition.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ProviderConfigurationSheet: View {
    let providerID: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var custom = CustomProviderStore.shared

    private var isLocal: Bool { providerID == EngineID.parakeet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isLocal ? String(localized: "Parakeet (local)") :
                    (ProviderCatalog.spec(providerID)?.name ?? EngineID.displayName(providerID)))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(18)

            Divider()
            if isLocal {
                ParakeetCard()
                    .padding(18)
            } else if let spec = ProviderCatalog.spec(providerID) {
                ScrollView {
                    ProviderConfigCard(spec: spec)
                        .padding(18)
                }
                .frame(height: 420)
            }
            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 570)
        .background(SoftWindowBackground())
    }
}

private struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var keyError: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New provider")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name, prompt: Text("Name"))
                TextField("Base URL", text: $baseURL, prompt: Text("https://…/v1"))
                SecureField("API key (optional)", text: $key, prompt: Text("API key (optional)"))
            }
            .textFieldStyle(.roundedBorder)

            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || ProviderSpec.validBaseURL(baseURL) == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(SoftWindowBackground())
    }

    private func add() {
        guard let url = ProviderSpec.validBaseURL(baseURL), !trimmedName.isEmpty else { return }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CustomProviderStore.shared.add(name: trimmedName, baseURL: url.absoluteString, key: trimmedKey) != nil else {
            keyError = String(localized: "The API key could not be saved.")
            return
        }
        ProviderHealth.shared.refresh(configurationOnly: true)
        dismiss()
    }
}

private struct ProviderConfigCard: View {
    let spec: ProviderSpec

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingChatModels = false
    @State private var showingASRModels = false
    @State private var showingRemove = false
    @State private var removeError = false

    private var transcriptionURL: String? { spec.id == EngineID.openAI ? settings.openAIBaseURL : nil }
    private var chatURL: String? { spec.id == EngineID.openAI ? settings.openAIChatBaseURL : nil }
    private var isCustom: Bool { ProviderCatalog.isCustom(spec.id) }

    private var chatBinding: Binding<String> {
        Binding(
            get: { settings.chatModel(for: spec.id) },
            set: { settings.setChatModel($0, for: spec.id) }
        )
    }

    private var asrBinding: Binding<String> {
        Binding(
            get: { settings.asrModel(for: spec.id) },
            set: { settings.setASRModel($0, for: spec.id) }
        )
    }

    var body: some View {
        SoftCard {
            if spec.requiresKey || isCustom {
                APIKeyRow(account: spec.keychainAccount, environmentKey: spec.environmentKey)
            }

            if spec.id == EngineID.openAI {
                SoftDivider()
                SoftRow("Base URL") {
                    TextField("Base URL", text: $settings.openAIBaseURL)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 232)
                }
                SoftDivider()
                SoftRow("Chat base URL", subtitle: "Optional. Uses the base URL above when empty.") {
                    TextField("Chat base URL", text: $settings.cleanupBaseURL)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 232)
                }
            } else if let provider = CustomProviderStore.shared.providers.first(where: { $0.id == spec.id }) {
                SoftDivider()
                CustomConnectionFields(provider: provider)
            }

            SoftDivider()

            SoftRow("Chat model", subtitle: "Used for cleanup, translation and editing") {
                HStack(spacing: 8) {
                    TextField("Chat model", text: chatBinding).labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 192)
                    Button {
                        showingChatModels = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .frame(width: 13)
                    }
                    .buttonStyle(SoftButtonStyle())
                    .help(Text("Browse")).accessibilityLabel(Text("Browse models"))
                }
            }

            if spec.supportsTranscription {
                SoftDivider()

                SoftRow("Supports transcription", subtitle: "Off hides this provider from the engine chain") {
                    Toggle("Supports transcription", isOn: Binding(
                        get: { settings.isASREnabled(for: spec.id) },
                        set: { settings.setASREnabled($0, for: spec.id) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            if spec.supportsTranscription, settings.isASREnabled(for: spec.id) {
                SoftDivider()

                SoftRow("Transcription model", subtitle: "Used when this provider is in the engine chain") {
                    HStack(spacing: 8) {
                        TextField("Transcription model", text: asrBinding).labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 192)
                        Button {
                            showingASRModels = true
                        } label: {
                            Image(systemName: "list.bullet")
                            .frame(width: 13)
                        }
                        .buttonStyle(SoftButtonStyle())
                        .help(Text("Browse")).accessibilityLabel(Text("Browse transcription models"))
                    }
                }
            }

            SoftDivider()
            ProviderTestRow(spec: spec, baseURL: chatURL, model: settings.chatModel(for: spec.id), title: "Test chat")

            if spec.supportsTranscription, settings.isASREnabled(for: spec.id) {
                SoftDivider()
                ProviderTestRow(spec: spec,
                                baseURL: transcriptionURL,
                                model: settings.asrModel(for: spec.id),
                                kind: .transcription,
                                title: "Test transcription")
            }

            if isCustom {
                SoftDivider()
                HStack {
                    Spacer()
                    Button("Remove provider…") { showingRemove = true }
                        .buttonStyle(SoftButtonStyle(destructive: true))
                }
                .padding(.vertical, 5)
                if removeError {
                    Text("The API key could not be removed.").foregroundStyle(Theme.warning)
                }
            }
        }
        .confirmationDialog("Remove this provider?", isPresented: $showingRemove, titleVisibility: .visible) {
            Button("Remove provider", role: .destructive) {
                guard Keychain.set(nil, account: spec.id) else {
                    removeError = true
                    return
                }
                settings.engineOrder.removeAll { $0 == spec.id }
                if settings.cleanupProvider == spec.id { settings.cleanupProvider = EngineID.groq }
                CustomProviderStore.shared.remove(id: spec.id)
                ProviderHealth.shared.refresh(configurationOnly: true)
                dismiss()
            }
        }
        .sheet(isPresented: $showingChatModels) {
            ModelChooser(spec: spec, baseURL: chatURL, selection: chatBinding)
        }
        .sheet(isPresented: $showingASRModels) {
            ModelChooser(spec: spec, baseURL: transcriptionURL, transcription: true, selection: asrBinding)
        }
    }
}

private struct CustomConnectionFields: View {
    let provider: CustomProvider
    @State private var name: String
    @State private var baseURL: String

    init(provider: CustomProvider) {
        self.provider = provider
        _name = State(initialValue: provider.name)
        _baseURL = State(initialValue: provider.baseURL)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validatedURL: URL? { ProviderSpec.validBaseURL(baseURL) }

    var body: some View {
        SoftRow("Name") {
            TextField("Name", text: $name)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 232)
        }
        SoftDivider()
        SoftRow("Base URL") {
            TextField("Base URL", text: $baseURL)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 232)
        }
        HStack {
            Spacer()
            Button("Save connection") {
                guard let validatedURL, !trimmedName.isEmpty else { return }
                CustomProviderStore.shared.update(id: provider.id, name: trimmedName,
                                                  baseURL: validatedURL.absoluteString)
                ProviderHealth.shared.refresh(configurationOnly: true)
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(trimmedName.isEmpty || validatedURL == nil ||
                      (provider.name == trimmedName && provider.baseURL == validatedURL?.absoluteString))
        }
        .padding(.vertical, 5)
    }
}

@MainActor
private final class ParakeetSettingsState: ObservableObject {
    static let shared = ParakeetSettingsState()

    @Published private(set) var busy = false
    @Published private(set) var error: String?

    func load() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await ParakeetRecognizer.shared.downloadIfNeeded()
                ProviderHealth.shared.refresh(configurationOnly: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ParakeetCard: View {
    @ObservedObject private var operation = ParakeetSettingsState.shared

    var body: some View {
        let configured = ParakeetRecognizer.shared.isConfigured()
        SoftCard {
            HStack(spacing: 10) {
                StatusDot(ok: configured)

                VStack(alignment: .leading, spacing: 2) {
                    Text(configured ? "Model ready" : "Model not downloaded")
                        .font(.system(size: 13))
                    Text("Offline fallback, 25 European languages, no key needed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    operation.load()
                } label: {
                    PendingActionLabel(title: configured ? "Load model" : "Download",
                                       pendingTitle: configured ? "Loading model…" : "Downloading…",
                                       isPending: operation.busy)
                }
                .buttonStyle(SoftProminentButtonStyle())
                .disabled(operation.busy)
            }
            .padding(.vertical, 6)

            if let error = operation.error {
                Text(error).font(.caption).foregroundStyle(Theme.warning)
                    .padding(.bottom, 6)
            }
        }
    }
}

private struct ProviderStatusLabel: View {
    let condition: ProviderCondition

    private var presentation: (symbol: String, color: Color) {
        switch condition {
        case .checking: ("clock", .secondary)
        case .reachable, .localReady: ("checkmark.circle", Theme.success)
        case .unverified: ("questionmark.circle", .secondary)
        case .unavailable: ("exclamationmark.circle", Theme.warning)
        }
    }

    var body: some View {
        Label(condition.title, systemImage: presentation.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(presentation.color)
    }
}

/// Chain only: the ordered list of configured transcription providers.
struct ChainSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var health = ProviderHealth.shared

    private var available: [ProviderSpec] {
        ProviderCatalog.transcriptionProviders.filter {
            $0.id != EngineID.parakeet
                && !settings.engineOrder.contains($0.id)
                && ProviderCatalog.isConfigured($0)
                && settings.isASREnabled(for: $0.id)
        }
    }

    private var canAddLocal: Bool {
        ParakeetRecognizer.shared.isConfigured() && !settings.engineOrder.contains(EngineID.parakeet)
    }

    var body: some View {
        VStack(spacing: 18) {
            SoftCard(title: "Chain", systemImage: "point.3.connected.trianglepath.dotted") {
                Text("Tacet tries engines in this order and uses the first successful transcript.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)

                SoftDivider()

                ForEach(Array(settings.engineOrder.enumerated()), id: \.offset) { index, engine in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(LinearGradient(colors: [Theme.accentStart, Theme.accentEnd],
                                                                     startPoint: .top, endPoint: .bottom)))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(ProviderCatalog.spec(engine)?.name ?? EngineID.displayName(engine)).font(.system(size: 13))
                            if settings.isASREnabled(for: engine) {
                                ProviderStatusLabel(condition: health.condition(for: targetID(for: engine)))
                            }
                            if let issue = issue(for: engine) {
                                Text(issue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(index == 0)
                            .accessibilityLabel(Text("Move up"))

                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(index == settings.engineOrder.count - 1)
                            .accessibilityLabel(Text("Move down"))

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                _ = settings.engineOrder.remove(at: index)
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(SoftButtonStyle(destructive: true))
                            .accessibilityLabel(Text("Remove from chain"))
                    }
                    .padding(.vertical, 5)
                }

                if canAddLocal || !available.isEmpty {
                    SoftDivider()
                    Menu("Add engine…") {
                        if canAddLocal {
                            Button("Parakeet (local)") { settings.engineOrder.append(EngineID.parakeet) }
                        }
                        ForEach(available) { provider in
                            Button(provider.name) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    settings.engineOrder.append(provider.id)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.vertical, 6)
                } else if settings.engineOrder.isEmpty {
                    Text("Set up a provider or download Parakeet to add an engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }

            SoftCard(title: "Network", systemImage: "clock") {
                SoftRow("Request timeout", subtitle: "Cloud engines only") {
                    Stepper("\(Int(settings.cloudTimeout)) s",
                            value: $settings.cloudTimeout, in: 5...60, step: 5)
                        .frame(width: 100)
                }
            }
        }
        .onAppear { health.refresh(configurationOnly: true) }
    }

    private func targetID(for engine: String) -> ProviderTarget.ID {
        .init(provider: engine, capability: engine == EngineID.parakeet ? .local : .transcription)
    }

    private func issue(for engine: String) -> String? {
        guard engine == EngineID.parakeet || ProviderCatalog.spec(engine) != nil else {
            return String(localized: "Not configured — will be skipped")
        }
        guard settings.isASREnabled(for: engine) else {
            return String(localized: "Transcription turned off in Providers")
        }
        return health.condition(for: targetID(for: engine)).reason
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.engineOrder.indices.contains(index),
              settings.engineOrder.indices.contains(destination) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            settings.engineOrder.swapAt(index, destination)
        }
    }
}
