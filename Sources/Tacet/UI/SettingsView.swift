import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            EnginesSettingsView()
                .tabItem { Label("Engines", systemImage: "cpu") }
            CleanupSettingsView()
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = TextInserter.isAccessibilityTrusted()

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: hotkeyBinding) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Picker("Mode", selection: $settings.hotkeyMode) {
                    Text("Push to talk (hold)").tag("hold")
                    Text("Toggle (press once)").tag("toggle")
                }

                if controller.hotkeyConflict {
                    Label("This hotkey is already taken by another app.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Language") {
                Picker("Language", selection: $settings.languageMode) {
                    ForEach(LanguageOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }

                Toggle("Re-check Ukrainian vs Russian", isOn: $settings.dualLanguageCheck)
                    .help("Runs a second decode only when the first result is ambiguous or contradicts the script. Costs one extra request in that case.")

                Text("Auto detects the language of every dictation separately, so you can switch chats and languages without changing settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Paste automatically", isOn: $settings.pasteAutomatically)
                Toggle("Show floating indicator", isOn: $settings.showHUD)
                Toggle("Play sounds", isOn: $settings.playSounds)

                Stepper("Keep audio for \(settings.keepAudioDays) days",
                        value: $settings.keepAudioDays, in: 1...90)
            }

            Section("Permissions") {
                HStack {
                    Circle()
                        .fill(micGranted ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text("Microphone")
                    Spacer()
                    if !micGranted {
                        Button("Grant") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .audio)
                                micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                            }
                        }
                    }
                }

                HStack {
                    Circle()
                        .fill(accessibilityGranted ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text("Accessibility (needed to paste into other apps)")
                    Spacer()
                    if !accessibilityGranted {
                        Button("Open Settings") {
                            TextInserter.requestAccessibility()
                            openAccessibilityPane()
                        }
                    }
                }

                if !accessibilityGranted {
                    Text("Without Accessibility the transcript is copied to the clipboard, ready for ⌘V.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
        Form {
            Section("Order") {
                Text("The first engine that returns text wins. Failed or unconfigured engines are skipped automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(settings.engineOrder.enumerated()), id: \.offset) { index, engine in
                    HStack {
                        Text("\(index + 1). \(EngineID.displayName(engine))")
                        Spacer()
                        Button {
                            move(index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)

                        Button {
                            move(index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == settings.engineOrder.count - 1)
                    }
                }
            }

            Section("Groq") {
                APIKeyField(title: "API key", account: KeychainAccount.groq, environmentKey: "GROQ_API_KEY")
                TextField("Model", text: $settings.groqModel)
                Text("whisper-large-v3-turbo is the fastest option and handles Ukrainian, Russian and English well.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI-compatible") {
                TextField("Base URL", text: $settings.openAIBaseURL)
                TextField("Model", text: $settings.openAIModel)
                APIKeyField(title: "API key", account: KeychainAccount.openAI, environmentKey: "OPENAI_API_KEY")
            }

            Section("Parakeet (local)") {
                ParakeetRow()
            }

            Section("Network") {
                Stepper("Request timeout: \(Int(settings.cloudTimeout)) s",
                        value: $settings.cloudTimeout, in: 5...60, step: 5)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.engineOrder.indices.contains(index),
              settings.engineOrder.indices.contains(destination) else { return }
        settings.engineOrder.swapAt(index, destination)
    }
}

private struct ParakeetRow: View {
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Offline fallback for 25 European languages, no key needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
                Button(ParakeetRecognizer.shared.isConfigured() ? "Reload" : "Download") {
                    download()
                }
                .disabled(busy)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { refreshStatus() }
    }

    private func refreshStatus() {
        status = ParakeetRecognizer.shared.isConfigured()
            ? "Model downloaded"
            : "Model not downloaded. The local fallback stays inactive until you download it."
    }

    private func download() {
        busy = true
        error = nil
        status = "Downloading… the app stays usable, dictation falls back to the cloud."

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
        Form {
            Section {
                Toggle("Clean up the transcript after recognition", isOn: $settings.cleanupEnabled)

                Text("The cleanup model fixes punctuation, capitalisation and obvious recognition errors. It never translates, never summarises, and its answer is discarded when it looks wrong or takes too long. The raw transcript is always available in History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Provider", selection: $settings.cleanupProvider) {
                    Text("Groq").tag(KeychainAccount.groq)
                    Text("OpenAI-compatible").tag(KeychainAccount.openAI)
                }

                TextField("Model", text: $settings.cleanupModel)

                if settings.cleanupProvider == KeychainAccount.openAI {
                    TextField("Base URL", text: $settings.cleanupBaseURL)
                }

                Stepper("Timeout: \(String(format: "%.1f", settings.cleanupTimeout)) s",
                        value: $settings.cleanupTimeout, in: 1...10, step: 0.5)

                Text("On timeout the raw transcript is inserted immediately. Cleanup must never make dictation feel slow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("Tacet").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Minimal dictation for macOS.\nGPL-3.0. Based on TypeWhisper.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Key field

struct APIKeyField: View {
    let title: String
    let account: String
    var environmentKey: String?

    @State private var value = ""
    @State private var saved = false
    @State private var configured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(title, text: $value)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }
                    .disabled(value.isEmpty && !configured)
                Button("Clear") { clear() }
                    .disabled(!configured && value.isEmpty)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(configured ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(configured ? "Key stored in Keychain" : "No key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let environmentKey,
                   ProcessInfo.processInfo.environment[environmentKey] != nil,
                   !configured {
                    Text("(\(environmentKey) is set in the environment)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        value = Keychain.string(account) ?? ""
        configured = !value.isEmpty
        saved = false
    }

    private func save() {
        Keychain.set(value, account: account)
        configured = Keychain.string(account) != nil
        saved = true
    }

    private func clear() {
        Keychain.set(nil, account: account)
        value = ""
        configured = false
        saved = false
    }
}
