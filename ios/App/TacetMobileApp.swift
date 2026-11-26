import AVFoundation
import SwiftUI

@main
struct TacetMobileApp: App {
    init() {
        #if DEBUG
        MobileGateway.provisionDevelopmentDevice()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            SessionView()
        }
    }
}

private struct SessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = MobileDictationSession.shared
    @State private var openedFromKeyboard = false
    @State private var settingsPath: [MobileSettingsPage] = []
    @State private var hasAccess = MobileGateway.isProvisioned
    @State private var showingAccess = false
    @State private var askingSoloDownload = false

    var body: some View {
        NavigationStack(path: $settingsPath) {
            Form {
                Section("Dictation session") {
                    if let deadline = session.deadline {
                        Label("Ready in the Tacet keyboard", systemImage: "mic.fill")
                            .foregroundStyle(.green)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if deadline <= context.date {
                                Text("Finishing your last dictation…")
                            } else {
                                let time = Duration.seconds(Int(ceil(deadline.timeIntervalSince(context.date))))
                                    .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
                                Text("Session time left: \(time)").monospacedDigit()
                            }
                        }
                        if !openedFromKeyboard {
                            Text("Open a text field and tap the microphone on the Tacet keyboard.")
                        }
                        Button("End session", role: .destructive) { session.end() }
                    } else {
                        if !openedFromKeyboard {
                            activationButton
                        }
                        Text("A session lasts 15 minutes. Tacet keeps audio only while you dictate.")
                    }
                    if !openedFromKeyboard, let message = session.message {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    NavigationLink(value: MobileSettingsPage.keyboard) {
                        Label("Keyboard", systemImage: "keyboard")
                    }
                    if hasAccess, ProviderCatalog.usesPilotGateway || EmailAccountClient().storedToken != nil {
                        NavigationLink(value: MobileSettingsPage.plan) {
                            Label("Plan and usage", systemImage: "chart.bar")
                        }
                    }
                    Button { showingAccess = true } label: {
                        Label("Tacet account", systemImage: "person.crop.circle")
                    }
                } footer: {
                    Text("Dictation audio and text for voice commands are sent through Tacet Gateway.")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if openedFromKeyboard {
                    keyboardReturnPanel
                }
            }
            .navigationTitle("Tacet")
            .navigationDestination(for: MobileSettingsPage.self) { page in
                page.destination
            }
        }
        .sheet(isPresented: $showingAccess) {
            MobileAccessSheet { connected in
                hasAccess = MobileGateway.isProvisioned
                if session.deadline != nil { session.end() }
                if connected, openedFromKeyboard { Task { await session.enableConfigured() } }
            }
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { openedFromKeyboard = false }
        }
        // Tacet Solo downloads by itself on Wi-Fi; over mobile data the user is asked once.
        // Tacet Solo завантажується сам через Wi-Fi; через мобільну мережу питаємо користувача один раз.
        .task(id: hasAccess) {
            askingSoloDownload = await SoloDownload.shared.startIfAppropriate(connected: hasAccess, canAsk: true)
        }
        .alert("Download Tacet Solo over mobile data?", isPresented: $askingSoloDownload) {
            Button("Download") { SoloDownload.shared.answerMetered(allow: true) }
            Button("Wait for Wi-Fi", role: .cancel) { SoloDownload.shared.answerMetered(allow: false) }
        } message: {
            Text("Tacet Solo keeps dictation working without a connection or when the limit is reached. The download is about 460 MB.")
        }
        .onOpenURL { url in
            guard DictationBridge.consumeWake(url) else { return }
            openedFromKeyboard = true
            settingsPath.removeAll()
            if hasAccess { Task { await session.enableConfigured() } }
            else { showingAccess = true }
        }
    }

    private var activationButton: some View {
        Button {
            if hasAccess { Task { await session.enableConfigured() } }
            else { showingAccess = true }
        } label: {
            if session.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing session…")
                }
            } else {
                if hasAccess { Label("Enable dictation", systemImage: "mic") }
                else { Label("Connect to Tacet", systemImage: "key") }
            }
        }
        .disabled(session.working)
    }

    private var keyboardReturnPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.deadline != nil {
                Label("Return to your text field", systemImage: "arrow.right")
                    .font(.headline)
                Text("Swipe right along the bottom edge of the screen, or use the system back arrow.")
                    .font(.subheadline)
                Text("If recording hasn’t started, tap the microphone on the Tacet keyboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if let message = session.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                activationButton
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .accessibilityIdentifier("keyboard-activation-panel")
    }
}
