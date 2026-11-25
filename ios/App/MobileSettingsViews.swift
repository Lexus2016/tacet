import SwiftUI

struct MobileAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var checking = false
    @State private var accountBusy = false
    @State private var error: String?
    let onCredentialChanged: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EmailAccountConnection(offersLegacyAccess: ProviderCatalog.usesPilotGateway || hasLegacyAccess,
                                           busy: $accountBusy, onCredentialChanged: didChangeAccount) {
                        legacyAccess
                    }
                    .disabled(checking)
                }
            }
            .navigationTitle("Tacet account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(checking || accountBusy)
                }
            }
        }
        .interactiveDismissDisabled(checking || accountBusy)
    }

    private var hasLegacyAccess: Bool {
        ProviderCatalog.spec(EngineID.hostedGateway).flatMap { Keychain.string($0.keychainAccount) } != nil
    }

    private var legacyAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Tacet access key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Tacet access key")
            Button(action: connect) {
                if checking { ProgressView("Checking access…") }
                else { Text("Connect") }
            }
            .disabled(checking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).foregroundStyle(.red) }
            Text("Use the access key you received for this iPhone.").font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(checking)
    }

    private func didChangeAccount(_ signedIn: Bool) {
        onCredentialChanged(signedIn)
        if signedIn { dismiss() }
    }

    private func connect() {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                try await MobileGateway.saveAccessKey(key)
                key = ""
                didChangeAccount(true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum MobileSettingsPage: Hashable {
    case keyboard, keyboardLanguages, plan

    @ViewBuilder
    var destination: some View {
        switch self {
        case .keyboard: MobileKeyboardSettings()
        case .keyboardLanguages: KeyboardLanguagesView()
        case .plan:
            Form { Section { AccountPlanView() } }
                .navigationTitle("Plan and usage")
        }
    }
}

private struct MobileKeyboardSettings: View {
    @AppStorage(MobilePreferences.translateToLayout) private var translatesToLayout = false

    var body: some View {
        Form {
            Section {
                NavigationLink("Keyboard languages", value: MobileSettingsPage.keyboardLanguages)
                Toggle("Translate to the keyboard language", isOn: $translatesToLayout)
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
            if let url = Bundle.main.url(forResource: "ATTRIBUTION", withExtension: "txt"),
               let credits = try? String(contentsOf: url, encoding: .utf8) {
                Section {
                    NavigationLink("Keyboard dictionary credits") {
                        ScrollView {
                            Text(credits).frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle("Keyboard dictionary credits")
                    }
                }
            }
        }
        .navigationTitle("Keyboard")
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
