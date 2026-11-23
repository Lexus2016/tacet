import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, engines, cleanup, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .engines: return "Engines"
            case .cleanup: return "Cleanup"
            case .about: return "About"
            }
        }
    }

    @State private var tab: Tab

    init(initialTab: Tab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    switch tab {
                    case .general: GeneralSettingsView()
                    case .engines: EnginesSettingsView()
                    case .cleanup: CleanupSettingsView()
                    case .about: AboutView()
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.955),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(width: 620, height: 660)
        .glassWindow()
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accentStart, Theme.accentEnd],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Theme.accent.opacity(0.14))
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
                    )

                Text("Tacet")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.2)

                Spacer()
            }
            .padding(.leading, 74)

            SoftSegmented(items: Tab.allCases, selection: $tab) { $0.title }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = TextInserter.isAccessibilityTrusted()

    var body: some View {
        VStack(spacing: 18) {
            SoftCard(title: "Dictation", systemImage: "command") {
                SoftRow("Hotkey") {
                    Picker("", selection: hotkeyBinding) {
                        ForEach(HotkeyPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SoftDivider()

                SoftRow("Mode", subtitle: settings.hotkeyMode == "hold"
                        ? "Hold the key while you speak"
                        : "Press once to start, once to stop") {
                    Picker("", selection: $settings.hotkeyMode) {
                        Text("Push to talk").tag("hold")
                        Text("Toggle").tag("toggle")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                if controller.hotkeyConflict {
                    SoftDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        Text("This hotkey is already taken by another app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                }
            }

            SoftCard(title: "Language", systemImage: "globe") {
                SoftRow("Language") {
                    Picker("", selection: $settings.languageMode) {
                        ForEach(LanguageOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                SoftDivider()

                SoftRow("Re-check Ukrainian vs Russian",
                        subtitle: "One extra request, only when the script check is ambiguous") {
                    Toggle("", isOn: $settings.dualLanguageCheck)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                Text("The language is detected for every dictation separately, so you can switch chats and languages without touching settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
            }

            SoftCard(title: "Behaviour", systemImage: "slider.horizontal.3") {
                SoftRow("Paste automatically", subtitle: "Otherwise the text is copied and waits for ⌘V") {
                    Toggle("", isOn: $settings.pasteAutomatically)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Floating indicator") {
                    Toggle("", isOn: $settings.showHUD)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Sounds") {
                    Toggle("", isOn: $settings.playSounds)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Keep audio", subtitle: "Recordings older than this are deleted, except failed ones") {
                    Stepper("\(settings.keepAudioDays) d",
                            value: $settings.keepAudioDays, in: 1...90)
                        .frame(width: 100)
                }
            }

            SoftCard(title: "Permissions", systemImage: "lock.shield") {
                SoftRow("Microphone", icon: nil) {
                    HStack(spacing: 10) {
                        StatusDot(ok: micGranted)
                        if !micGranted {
                            Button("Grant") {
                                Task {
                                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                                    micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                                }
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                    }
                }

                SoftDivider()

                SoftRow("Accessibility", subtitle: "Needed to paste into other apps") {
                    HStack(spacing: 10) {
                        StatusDot(ok: accessibilityGranted)
                        if !accessibilityGranted {
                            Button("Open") {
                                TextInserter.requestAccessibility()
                                openAccessibilityPane()
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = TextInserter.isAccessibilityTrusted()
        }
    }

    private var hotkeyBinding: Binding<HotkeyPreset> {
        Binding(
            get: {
                HotkeyPreset.matching(keyCode: settings.hotkeyKeyCode,
                                      modifiers: settings.hotkeyModifiers) ?? .optionSpace
            },
            set: { preset in
                settings.hotkeyKeyCode = Int(preset.keyCode)
                settings.hotkeyModifiers = Int(preset.modifiers)
                controller.configureHotkey()
            }
        )
    }

    private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Engines

struct EnginesSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 18) {
            SoftCard(title: "Chain", systemImage: "point.3.connected.trianglepath.dotted") {
                Text("The first engine that returns text wins. Unconfigured or failing engines are skipped automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)

                SoftDivider()

                ForEach(Array(settings.engineOrder.enumerated()), id: \.offset) { index, engine in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(
                                    LinearGradient(colors: [Theme.accentStart, Theme.accentEnd],
                                                   startPoint: .top, endPoint: .bottom)
                                )
                            )

                        Text(EngineID.displayName(engine))
                            .font(.system(size: 13))

                        Spacer()

                        Button {
                            move(index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(index == 0)

                        Button {
                            move(index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(index == settings.engineOrder.count - 1)
                    }
                    .padding(.vertical, 6)
                }
            }

            SoftCard(title: "Groq", systemImage: "bolt.fill") {
                APIKeyRow(account: KeychainAccount.groq, environmentKey: "GROQ_API_KEY")
                SoftDivider()
                SoftRow("Model") {
                    TextField("", text: $settings.groqModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                }
                Text("whisper-large-v3-turbo is fast and strong on Ukrainian, Russian and English.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
            }

            SoftCard(title: "OpenAI-compatible", systemImage: "server.rack") {
                SoftRow("Base URL") {
                    TextField("", text: $settings.openAIBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                SoftDivider()
                SoftRow("Model") {
                    TextField("", text: $settings.openAIModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                SoftDivider()
                APIKeyRow(account: KeychainAccount.openAI, environmentKey: "OPENAI_API_KEY")
            }

            SoftCard(title: "Parakeet (local)", systemImage: "cpu") {
                ParakeetRow()
            }

            SoftCard(title: "Network", systemImage: "clock") {
                SoftRow("Request timeout", subtitle: "Cloud engines only") {
                    Stepper("\(Int(settings.cloudTimeout)) s",
                            value: $settings.cloudTimeout, in: 5...60, step: 5)
                        .frame(width: 90)
                }
            }

            Text("Audio is uploaded only to the cloud engines enabled here. The local engine keeps it on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
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

private struct ParakeetRow: View {
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

                if busy {
                    ProgressView().controlSize(.small)
                }

                Button(ParakeetRecognizer.shared.isConfigured() ? "Reload" : "Download") {
                    download()
                }
                .buttonStyle(SoftProminentButtonStyle())
                .disabled(busy)
            }
            .padding(.vertical, 7)

            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        }
        .onAppear(perform: refreshStatus)
    }

    private func refreshStatus() {
        status = ParakeetRecognizer.shared.isConfigured()
            ? "Loaded from the previous download."
            : "Dictation falls back to the cloud until this is downloaded."
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

// MARK: - Cleanup

struct CleanupSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 18) {
            SoftCard(title: "Cleanup", systemImage: "wand.and.stars") {
                SoftRow("Clean up after recognition",
                        subtitle: "Fix punctuation, casing and obvious recognition errors") {
                    Toggle("", isOn: $settings.cleanupEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                Text("The cleanup model never translates, never summarises, and its answer is discarded when it looks wrong or takes too long. The raw transcript stays available in History.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
            }

            SoftCard(title: "Model", systemImage: "brain") {
                SoftRow("Provider") {
                    Picker("", selection: $settings.cleanupProvider) {
                        Text("Groq").tag(KeychainAccount.groq)
                        Text("OpenAI-compatible").tag(KeychainAccount.openAI)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                SoftDivider()

                SoftRow("Model") {
                    TextField("", text: $settings.cleanupModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                }

                if settings.cleanupProvider == KeychainAccount.openAI {
                    SoftDivider()
                    SoftRow("Base URL") {
                        TextField("", text: $settings.cleanupBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                    }
                }

                SoftDivider()

                SoftRow("Timeout", subtitle: "On timeout the raw transcript is inserted") {
                    Stepper(String(format: "%.1f s", settings.cleanupTimeout),
                            value: $settings.cleanupTimeout, in: 1...10, step: 0.5)
                        .frame(width: 100)
                }

                SoftDivider()

                CleanupTestRow()
            }
        }
    }
}

private struct CleanupTestRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Try it on a sample sentence")
                    .font(.system(size: 13))
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
                Button("Test") { run() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(busy || !settings.isCleanupConfigured)
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }

    private func run() {
        busy = true
        message = nil

        let secondary: String? = settings.cleanupProvider == KeychainAccount.groq
            ? KeychainAccount.openAI
            : KeychainAccount.groq
        let configuration = CleanupConfiguration(
            provider: settings.cleanupProvider,
            baseURL: settings.cleanupBaseURL,
            model: settings.cleanupModel,
            timeout: settings.cleanupTimeout,
            secondaryProvider: secondary
        )

        Task {
            let result = await CleanupPipeline().clean("привіт як справи це тест пунктуації", configuration: configuration)
            if result.engine == "none" {
                message = "Failed. The raw transcript would be used instead. Check the model name and the key."
            } else {
                message = "\(result.engine): \(result.text)"
            }
            busy = false
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: Theme.accent.opacity(0.45), radius: 20, y: 10)
                    .padding(.top, 12)

                Text("Tacet")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(0.2)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("Minimal dictation for macOS.\nGPL-3.0, based on TypeWhisper.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                shape
                    .fill(Theme.cardFill(.dark))
                    .overlay(shape.stroke(Theme.cardStroke(.dark), lineWidth: 1))
                    .shadow(color: Theme.shadow(.dark), radius: 18, y: 9)
            }
        }
    }
}

// MARK: - Key field

struct APIKeyRow: View {
    let account: String
    var environmentKey: String?

    @State private var value = ""
    @State private var configured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(ok: configured)

                Text("API key")
                    .font(.system(size: 13))

                Spacer()

                Button("Save") { save() }
                    .buttonStyle(SoftProminentButtonStyle())
                    .disabled(value.isEmpty && !configured)

                Button("Clear") { clear() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!configured && value.isEmpty)
            }

            SecureField("Paste the key", text: $value)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Text(configured ? "Stored in the Keychain" : "No key")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                if let environmentKey,
                   ProcessInfo.processInfo.environment[environmentKey] != nil,
                   !configured {
                    Text("· \(environmentKey) is set in the environment")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 18)
        }
        .padding(.vertical, 8)
        .onAppear(perform: load)
    }

    private func load() {
        value = Keychain.string(account) ?? ""
        configured = !value.isEmpty
    }

    private func save() {
        Keychain.set(value, account: account)
        configured = Keychain.string(account) != nil
    }

    private func clear() {
        Keychain.set(nil, account: account)
        value = ""
        configured = false
    }
}
