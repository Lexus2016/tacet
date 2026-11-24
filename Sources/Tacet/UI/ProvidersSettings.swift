import SwiftUI

/// One tab for every provider: key, models, a real connection test and the
/// option to remove it from the chains. Engines and Cleanup only ever list what
/// is configured here.
struct ProvidersSettingsView: View {
    static let configurationAnchor = "provider-configuration"
    let showConfiguration: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var custom = CustomProviderStore.shared
    @ObservedObject private var health = ProviderHealth.shared

    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newKey = ""
    @State private var editingProvider: CustomProvider?
    @State private var keyError: String?
    @State private var selectedProvider = EngineID.groq

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            overview

            SoftCard(title: "Provider connections", systemImage: "server.rack") {
                SoftRow("Provider") {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(ProviderCatalog.all) { spec in
                            Text(spec.name).tag(spec.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 204)
                }
                SoftDivider()
                HStack(spacing: 8) {
                    Spacer()
                    if let provider = custom.providers.first(where: { $0.id == selectedProvider }) {
                        Button("Edit connection…") { openForm(provider) }
                            .buttonStyle(SoftButtonStyle())
                    }
                    Button {
                        openForm(nil)
                    } label: {
                        Label("Add provider…", systemImage: "plus")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                .padding(.vertical, 4)
            }

            if let spec = ProviderCatalog.spec(selectedProvider) {
                VStack {
                    ProviderConfigCard(spec: spec).id(spec.id)
                }
                .id(Self.configurationAnchor)
            }

            ParakeetCard()
        }
        .onAppear { health.refresh(configurationOnly: true) }
        .onChange(of: custom.providers) { _, _ in
            if ProviderCatalog.spec(selectedProvider) == nil { selectedProvider = EngineID.groq }
        }
        .sheet(isPresented: $showingAdd) {
            VStack(alignment: .leading, spacing: 12) {
                Text(editingProvider == nil ? "New provider" : "Edit connection")
                    .font(.headline)

                TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
                TextField("Base URL (https://…/v1)", text: $newURL).textFieldStyle(.roundedBorder)
                if editingProvider == nil {
                    SecureField("API key (optional)", text: $newKey).textFieldStyle(.roundedBorder)
                }

                if let keyError {
                    Text(keyError).foregroundStyle(Theme.warning)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { showingAdd = false }
                        .keyboardShortcut(.cancelAction)
                    Button(editingProvider == nil ? "Add" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(ProviderSpec.validBaseURL(newURL) == nil ||
                                  newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
            .frame(width: 410)
        }
    }

    private var providerIDs: [String] {
        var seen = Set<String>()
        return health.targets.map(\.id.provider).filter { seen.insert($0).inserted }
    }

    private var overview: some View {
        SoftCard(title: "Provider overview", systemImage: "network") {
            if health.targets.isEmpty {
                Text("No providers are connected or in use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
            ForEach(providerIDs, id: \.self) { provider in
                let targets = health.targets.filter { $0.id.provider == provider }
                if let first = targets.first {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(first.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            if first.id.capability != .local {
                                Button("Configure") {
                                    selectedProvider = provider
                                    showConfiguration()
                                }
                                    .buttonStyle(SoftButtonStyle())
                            }
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
                    SoftDivider()
                }
            }
            HStack {
                Text("Connections are checked every minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check now") { health.refresh() }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.vertical, 6)
        }
    }

    private func openForm(_ provider: CustomProvider?) {
        editingProvider = provider
        newName = provider?.name ?? ""
        newURL = provider?.baseURL ?? ""
        newKey = ""
        keyError = nil
        showingAdd = true
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ProviderSpec.validBaseURL(newURL), !name.isEmpty else { return }
        if let provider = editingProvider {
            custom.update(id: provider.id, name: name, baseURL: url.absoluteString)
        } else {
            let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = custom.add(name: name, baseURL: url.absoluteString, key: key) else {
                keyError = String(localized: "The API key could not be saved.")
                return
            }
            selectedProvider = id
        }
        newKey = ""
        showingAdd = false
    }
}

private struct ProviderConfigCard: View {
    let spec: ProviderSpec

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
        SoftCard(title: spec.name, systemImage: "server.rack") {
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
            } else if isCustom {
                SoftDivider()
                SoftRow("Base URL") {
                    Text(spec.baseURL)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
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
                        .help(Text("Browse")).accessibilityLabel(Text("Browse models"))
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

private struct ParakeetCard: View {
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        SoftCard(title: "Parakeet (local)", systemImage: "cpu") {
            HStack(spacing: 10) {
                StatusDot(ok: ParakeetRecognizer.shared.isConfigured())

                VStack(alignment: .leading, spacing: 2) {
                    Text(ParakeetRecognizer.shared.isConfigured() ? "Model ready" : "Model not downloaded")
                        .font(.system(size: 13))
                    Text("Offline fallback, 25 European languages, no key needed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if busy { ProgressView().controlSize(.small) }

                Button(ParakeetRecognizer.shared.isConfigured() ? "Reload" : "Download") {
                    download()
                }
                .buttonStyle(SoftProminentButtonStyle())
                .disabled(busy)
            }
            .padding(.vertical, 6)

            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        }
        .onAppear {
            status = ""
        }
    }

    private func download() {
        busy = true
        error = nil
        status = "Downloading… the app stays usable meanwhile."
        Task {
            do {
                try await ParakeetRecognizer.shared.downloadIfNeeded()
                status = "Model ready"
                ProviderHealth.shared.refresh()
            } catch {
                self.error = error.localizedDescription
                status = "Download failed"
            }
            busy = false
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
