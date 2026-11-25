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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = MobileDictationSession.shared
    @State private var openedFromKeyboard = false
    @State private var settingsPath: [MobileSettingsPage] = []

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

                Section("Settings") {
                    ForEach(MobileSettingsPage.menu, id: \.self) { page in
                        NavigationLink(value: page) {
                            page.menuLabel
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if openedFromKeyboard {
                    keyboardReturnPanel
                }
            }
            .navigationTitle("Tacet")
            .navigationDestination(for: MobileSettingsPage.self) { page in
                page.destination(locked: session.deadline != nil || session.working)
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
        .onOpenURL { url in
            guard DictationBridge.consumeWake(url) else { return }
            openedFromKeyboard = true
            settingsPath.removeAll()
            Task { await session.enableConfigured() }
        }
    }

    private var activationButton: some View {
        Button {
            Task { await session.enableConfigured() }
        } label: {
            if session.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing session…")
                }
            } else {
                Label("Enable dictation", systemImage: "mic")
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
