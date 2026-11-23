import SwiftUI

/// One tab for every provider: key, models, a real connection test and the
/// option to remove it from the chains. Engines and Cleanup only ever list what
/// is configured here.
struct ProvidersSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 14) {
            Text("Configure a provider once. Engines and Cleanup only offer the providers configured here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            ForEach(ProviderCatalog.all) { spec in
                if spec.id == "openai" {
                    ProviderConfigCard(spec: spec, showsBaseURL: true)
                } else {
                    ProviderConfigCard(spec: spec)
                }
            }

            ParakeetCard()
        }
    }
}

private struct ProviderConfigCard: View {
    let spec: ProviderSpec
    var showsBaseURL = false

    @ObservedObject private var settings = AppSettings.shared
    @State private var showingChatModels = false
    @State private var showingASRModels = false

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
            if spec.requiresKey {
                APIKeyRow(account: spec.keychainAccount, environmentKey: spec.environmentKey)
            }

            if showsBaseURL {
                SoftDivider()
                SoftRow("Base URL") {
                    TextField("", text: $settings.openAIBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
            }

            SoftDivider()

            SoftRow("Model", subtitle: "Used for cleanup, translation and editing") {
                HStack(spacing: 8) {
                    TextField("", text: chatBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                    Button {
                        showingChatModels = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .help(Text("Browse"))
                }
            }

            if spec.supportsTranscription {
                SoftDivider()

                SoftRow("Supports transcription", subtitle: "Off hides this provider from the engine chain") {
                    Toggle("", isOn: Binding(
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
                        TextField("", text: asrBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                        Button {
                            showingASRModels = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .buttonStyle(SoftButtonStyle())
                        .help(Text("Browse"))
                    }
                }
            }

            SoftDivider()

            ProviderTestRow(spec: spec, model: settings.chatModel(for: spec.id), title: "Test chat")

            if spec.supportsTranscription, settings.isASREnabled(for: spec.id) {
                SoftDivider()
                ProviderTestRow(spec: spec,
                                model: settings.asrModel(for: spec.id),
                                kind: .transcription,
                                title: "Test transcription")
            }
        }
        .sheet(isPresented: $showingChatModels) {
            ModelChooser(spec: spec,
                         baseURL: spec.id == "openai" ? settings.openAIBaseURL : nil,
                         selection: chatBinding)
        }
        .sheet(isPresented: $showingASRModels) {
            ModelChooser(spec: spec,
                         baseURL: spec.id == "openai" ? settings.openAIBaseURL : nil,
                         selection: asrBinding)
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
            status = ParakeetRecognizer.shared.isConfigured()
                ? "Loaded from the previous download."
                : "Dictation falls back to the cloud until this is downloaded."
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
            } catch {
                self.error = error.localizedDescription
                status = "Download failed"
            }
            busy = false
        }
    }
}

/// Chain only: the ordered list of configured transcription providers.
struct ChainSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    private var available: [ProviderSpec] {
        ProviderCatalog.transcriptionProviders.filter {
            $0.id != EngineID.parakeet
                && !settings.engineOrder.contains($0.id)
                && ProviderCatalog.isConfigured($0)
                && settings.isASREnabled(for: $0.id)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            SoftCard(title: "Chain", systemImage: "point.3.connected.trianglepath.dotted") {
                Text("The first engine that returns text wins. Only configured providers are listed; failed ones are skipped.")
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
                            Text(EngineID.displayName(engine)).font(.system(size: 13))
                            if !ProviderCatalog.isConfigured(ProviderCatalog.spec(engine) ?? ProviderCatalog.all[0])
                                && engine != EngineID.parakeet {
                                Text("Not configured — will be skipped")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.warning)
                            }
                        }

                        Spacer()

                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(index == 0)

                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(index == settings.engineOrder.count - 1)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                settings.engineOrder.remove(at: index)
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(SoftButtonStyle(destructive: true))
                    }
                    .padding(.vertical, 5)
                }

                if !available.isEmpty {
                    SoftDivider()
                    Menu("Add provider…") {
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
                }
            }
        }
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
