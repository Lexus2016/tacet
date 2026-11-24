import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, providers, engines, cleanup, about

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .providers: return "server.rack"
            case .engines: return "waveform"
            case .cleanup: return "text.badge.checkmark"
            case .about: return "info.circle"
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .providers: return "Providers"
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
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(LocalizedStringKey(tab.title))
                            .font(.system(size: 25, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)

                        switch tab {
                        case .general: GeneralSettingsView()
                        case .providers:
                            ProvidersSettingsView {
                                scroll.scrollTo(ProvidersSettingsView.configurationAnchor, anchor: .top)
                            }
                        case .engines: ChainSettingsView()
                        case .cleanup: CleanupSettingsView()
                        case .about: AboutView()
                        }
                    }
                    .frame(maxWidth: 710, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .id(tab)
            .accessibilityIdentifier("settings-content")
        }
        .background(SoftWindowBackground())
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        List(selection: Binding<Tab?>(
            get: { tab },
            set: { if let selection = $0 { tab = selection } }
        )) {
            ForEach(Tab.allCases) { item in
                Label(LocalizedStringKey(item.title), systemImage: item.symbol)
                    .font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(minHeight: 34, alignment: .leading)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.top, 10)
        .frame(width: 174)
        .background(.quaternary.opacity(0.12))
    }

}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = TextInserter.isAccessibilityTrusted()
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 18) {
            SoftCard(title: "Dictation", systemImage: "command") {
                SoftRow("Hotkey", subtitle: "Click, then press the combination you want. You can also use a single ⌘, ⌥, ⌃ or ⇧.") {
                    HotkeyRecorder(keyCode: $settings.hotkeyKeyCode,
                                   modifiers: $settings.hotkeyModifiers,
                                   label: $settings.hotkeyLabel,
                                   onChange: { controller.configureHotkey() })
                }

                SoftDivider()

                SoftRow("Mode", subtitle: settings.hotkeyMode == "hold"
                        ? "Hold the key while you speak"
                        : "Press once to start, once to stop") {
                    Picker("Mode", selection: $settings.hotkeyMode) {
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
                        Text("This combination is taken by another app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                } else if !controller.activeHotkey.isEmpty,
                          controller.activeHotkey != HotkeyFormat.title(keyCode: settings.hotkeyKeyCode,
                                                                         modifiers: settings.hotkeyModifiers,
                                                                         label: settings.hotkeyLabel) {
                    SoftDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text("\(HotkeyFormat.title(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers, label: settings.hotkeyLabel)) is taken. Tacet is listening on \(controller.activeHotkey).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                }
            }

            SoftCard(title: "Language", systemImage: "globe") {
                SoftRow("Language") {
                    Picker("Language", selection: $settings.languageMode) {
                        ForEach(LanguageOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                SoftDivider()

                SoftRow("Output language",
                        subtitle: "Dictate in any language; the inserted text is in this one") {
                    Picker("Output language", selection: $settings.outputLanguage) {
                        Text("Same as spoken").tag("auto")
                        ForEach(LanguageOption.allCases.filter { $0 != .auto }) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                SoftDivider()

                SoftRow("Second language check",
                        subtitle: "When the script is ambiguous, try the likely alternative: Ukrainian/Russian, Belarusian/Russian, Polish/Ukrainian and similar pairs") {
                    Toggle("Second language check", isOn: $settings.dualLanguageCheck)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Voice language check",
                        subtitle: "Listens to the clip with Gemini Decision, so Ukrainian speech decoded as Russian is caught. Needs an OpenRouter key.") {
                    Toggle("Voice language check", isOn: $settings.voiceLanguageCheck)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                Text("The language is detected for every dictation separately, so you can switch chats and languages without touching settings. Tacet also remembers the language you last used in each app, which skips the extra check when you come back.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
            }

            SoftCard(title: "Behaviour", systemImage: "slider.horizontal.3") {
                SoftRow("Paste automatically", subtitle: "Keeps your existing clipboard. Turn off to copy dictations for manual pasting.") {
                    Toggle("Paste automatically", isOn: $settings.pasteAutomatically)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Edit selected text",
                        subtitle: "With text selected, the dictation rewrites, translates or removes it instead of inserting after it") {
                    Toggle("Edit selected text", isOn: $settings.selectionEditing)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Floating indicator") {
                    Toggle("Floating indicator", isOn: $settings.showHUD)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Sounds", subtitle: "Short Tacet cues for start, success and errors") {
                    Toggle("Sounds", isOn: $settings.playSounds)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Launch at login", subtitle: loginHint) {
                    Toggle("Launch at login", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SoftDivider()

                SoftRow("Interface language", subtitle: "Restart Tacet to apply") {
                    HStack(spacing: 8) {
                        Picker("Interface language", selection: $settings.uiLanguage) {
                            Text("System").tag("system")
                            Text("English").tag("en")
                            Text("Українська").tag("uk")
                            Text("Français").tag("fr")
                            Text("Español").tag("es")
                            Text("Deutsch").tag("de")
                            Text("Português").tag("pt")
                            Text("中文").tag("zh-Hans")
                            Text("हिन्दी").tag("hi")
                        }
                        .labelsHidden()
                        .frame(width: 150)

                        Button {
                            relaunch()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(SoftButtonStyle())
                        .help(Text("Restart"))
                    }
                }

                SoftDivider()

                SoftRow("Keep audio", subtitle: "Recordings older than this are deleted, except failed ones") {
                    Stepper("\(settings.keepAudioDays) d",
                            value: $settings.keepAudioDays, in: 1...90)
                        .frame(width: 100)
                }
            }

            SoftCard(title: "Floating indicator", systemImage: "sparkles") {
                SoftRow("Theme") {
                    Picker("Theme", selection: $settings.indicatorTheme) {
                        ForEach(IndicatorTheme.allCases) { theme in
                            Text(LocalizedStringKey(theme.title)).tag(theme.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                SoftDivider()

                SoftRow("Position", subtitle: "Where the indicator appears") {
                    Picker("Position", selection: $settings.indicatorPosition) {
                        Text("Bottom").tag("bottom")
                        Text("Top").tag("top")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                SoftDivider()

                SoftRow("Preview", subtitle: "Shows the selected style for three seconds") {
                    Button("Show") {
                        HUDController.shared.preview()
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }

            SoftCard(title: "Permissions", systemImage: "lock.shield") {
                SoftRow("Microphone", icon: nil) {
                    HStack(spacing: 10) {
                        StatusDot(ok: micGranted)
                        if !micGranted {
                            Button("Grant") {
                                Task {
                                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                                    } else {
                                        openPrivacyPane("Microphone")
                                    }
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
                                openPrivacyPane("Accessibility")
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let trusted = TextInserter.isAccessibilityTrusted()
            if trusted && !accessibilityGranted { controller.configureHotkey() }
            accessibilityGranted = trusted
        }
    }

    private func openPrivacyPane(_ category: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(category)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { value in
                do {
                    try LoginItem.set(value)
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
                launchAtLogin = LoginItem.isEnabled
            }
        )
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private var loginHint: String {
        if let loginError { return loginError }
        if Bundle.main.bundlePath.hasPrefix("/Applications") {
            return "Start Tacet when you log in"
        }
        return "Move Tacet to /Applications to enable this"
    }


}

// MARK: - Cleanup

struct CleanupSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    private var providers: [ProviderSpec] {
        ProviderCatalog.chatProviders.filter { ProviderCatalog.isConfigured($0) }
    }

    var body: some View {
        VStack(spacing: 18) {
            SoftCard(title: "Cleanup", systemImage: "wand.and.stars") {
                SoftRow("Clean up after recognition",
                        subtitle: "Fix punctuation, casing and obvious recognition errors") {
                    Toggle("Clean up after recognition", isOn: $settings.cleanupEnabled)
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
                SoftRow("Provider", subtitle: "Set the model and credentials in Providers.") {
                    Picker("Provider", selection: $settings.cleanupProvider) {
                        if !providers.contains(where: { $0.id == settings.cleanupProvider }) {
                            Text("Choose a provider").tag(settings.cleanupProvider)
                        }
                        ForEach(providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 204)
                }

                if providers.contains(where: { $0.id == settings.cleanupProvider }) {
                    SoftDivider()
                    SoftRow("Chat model") {
                        let model = settings.chatModel(for: settings.cleanupProvider)
                        Text(model.isEmpty ? String(localized: "Choose a model first.") : model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

        let configuration = CleanupConfiguration(
            provider: settings.cleanupProvider,
            baseURL: settings.openAIChatBaseURL,
            model: settings.chatModel(for: settings.cleanupProvider),
            timeout: settings.cleanupTimeout
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
        SoftCard {
            HStack(alignment: .top, spacing: 17) {
                Image(nsImage: TacetIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Tacet")
                        .font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Dictate into your editor with a keyboard shortcut. Use on-device recognition or connect a cloud provider. Tacet keeps your clipboard intact when it inserts text automatically.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)

            SoftDivider()
            HStack {
                Link("Source code", destination: URL(string: "https://github.com/Lexus2016/tacet")!)
                Text("GPL-3.0 · Based on TypeWhisper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Key field

struct APIKeyRow: View {
    let account: String
    var environmentKey: String?

    @State private var value = ""
    @State private var configured = false
    @State private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(ok: configured)

                Text("API key")
                    .font(.system(size: 13))

                Spacer()

                Button("Save") { save() }
                    .buttonStyle(SoftProminentButtonStyle())
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Clear") { clear() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!configured)
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

            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 8)
        .onAppear(perform: load)
    }

    private func load() {
        configured = Keychain.string(account) != nil
    }

    private func save() {
        guard Keychain.set(value, account: account) else {
            keyError = String(localized: "The API key could not be saved.")
            return
        }
        value = ""
        keyError = nil
        load()
        ProviderHealth.shared.credentialChanged(account)
    }

    private func clear() {
        guard Keychain.set(nil, account: account) else {
            keyError = String(localized: "The API key could not be removed.")
            return
        }
        value = ""
        keyError = nil
        load()
        ProviderHealth.shared.credentialChanged(account)
    }
}
