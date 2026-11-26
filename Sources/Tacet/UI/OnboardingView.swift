import AVFoundation
import SwiftUI

/// The first-run tour: a progress rail on the left, one hands-on step on the right.
/// Знайомство під час першого запуску: ліворуч шкала кроків, праворуч один практичний крок.
struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var tour: Onboarding

    init(tour: Onboarding = .shared) { self.tour = tour }
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    @State private var practice = ""
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = TextInserter.isAccessibilityTrusted()
    @State private var savedOutputLanguage: String?
    @State private var savedPaste: Bool?
    @FocusState private var practiceFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        stepBody
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 26)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .background(SoftWindowBackground())
        .onAppear { enter(tour.step) }
        .onChange(of: tour.step) { old, new in
            leave(old)
            enter(new)
        }
        .onChange(of: tour.isComplete) { _, done in
            if done {
                leave(tour.step)
                AppWindows.shared.closeOnboarding()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let trusted = TextInserter.isAccessibilityTrusted()
            if trusted && !accessibilityGranted { controller.configureHotkey() }
            accessibilityGranted = trusted
        }
    }

    // MARK: Chrome

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Tacet")
                .font(.system(size: 17, weight: .semibold))
                .padding(.bottom, 2)
            Text("Ten short steps. Each one is something you do, not something you read.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            ForEach(Onboarding.Step.allCases) { step in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(tour.finished.contains(step) ? Theme.success
                                  : step == tour.step ? Theme.accent : Theme.trackFill(scheme))
                            .frame(width: 22, height: 22)
                        if tour.finished.contains(step) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(step == tour.step ? .white : .secondary)
                        }
                    }
                    Text(title(step))
                        .font(.system(size: 12.5, weight: step == tour.step ? .semibold : .regular))
                        .foregroundStyle(step == tour.step ? .primary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .frame(width: 264, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step \(tour.step.rawValue + 1) of \(Onboarding.Step.allCases.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .textCase(.uppercase)
            Text(title(tour.step)).font(.system(size: 26, weight: .bold))
            Text(summary(tour.step))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if tour.canContinue {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Label(waiting(tour.step), systemImage: "circle.dotted").foregroundStyle(.secondary)
                    .font(.system(size: 12.5))
            }
            Spacer()
            if tour.step != .key {
                Button("Back") { tour.back() }.buttonStyle(SoftButtonStyle())
            }
            Button(tour.isLast ? "Start using Tacet" : "Continue") { tour.advance() }
                .buttonStyle(SoftProminentButtonStyle())
                .disabled(!tour.canContinue)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    // MARK: Steps

    @ViewBuilder private var stepBody: some View {
        switch tour.step {
        case .key:
            SoftCard(title: "Permissions", systemImage: "lock.shield") {
                SoftRow("Microphone") {
                    HStack(spacing: 10) {
                        StatusDot(ok: micGranted)
                        if !micGranted { Button("Grant") { requestMicrophone() }.buttonStyle(SoftButtonStyle()) }
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
                            }.buttonStyle(SoftButtonStyle())
                        }
                    }
                }
            }
            SoftCard(title: "Dictation", systemImage: "command") {
                SoftRow("Hotkey", subtitle: "Click, then press the combination you want. You can also use a single ⌘, ⌥, ⌃ or ⇧.") {
                    HotkeyRecorder(keyCode: $settings.hotkeyKeyCode, modifiers: $settings.hotkeyModifiers,
                                   label: $settings.hotkeyLabel, onRecordingChange: controller.setHotkeyRecording)
                        .disabled(controller.phase != .idle)
                }
                SoftDivider()
                SoftRow("Mode", subtitle: settings.hotkeyMode == "hold" ? "Hold the key while you speak"
                        : "Press once to start, once to stop") {
                    SettingsPicker(title: "Mode", selection: $settings.hotkeyMode,
                                   options: [.init("hold", "Push to talk"), .init("toggle", "Toggle")])
                        .frame(width: Theme.settingsControlWidth)
                }
            }
            task("Press \(keyName) now and watch the indicator appear.")
        case .dictate:
            say("Say anything, for example:", "I will send the report on Friday morning.")
            field
        case .correct:
            say("Say it the way people really talk, with a slip:", "Let’s meet on Tuesday, no, on Wednesday at three.")
            if let last = tour.last {
                compare("What was heard", last.raw, "What Tacet wrote", last.text)
            }
            field
        case .languages:
            say("Dictate one phrase, then another in a different language. Nothing to switch.", "Good morning! … Доброго ранку!")
            if settings.languageMode != "auto" {
                HStack {
                    Text("A fixed language is selected, so Tacet will not detect it.").font(.system(size: 12.5))
                    Button("Detect automatically") { settings.languageMode = "auto" }.buttonStyle(SoftButtonStyle())
                }
            }
            if !tour.languages.isEmpty {
                HStack(spacing: 8) {
                    Text("Heard so far:").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    ForEach(tour.languages, id: \.self) { SoftChip(text: $0.uppercased()) }
                }
            }
            field
        case .translate:
            SoftCard {
                SoftRow("Output language", subtitle: "Dictate in any language; the inserted text is in this one") {
                    SettingsPicker(title: "Output language", selection: $settings.outputLanguage,
                                   options: LanguageOption.allCases.map {
                        .init($0.rawValue, $0 == .auto ? "Same as spoken" : $0.title)
                    })
                    .frame(width: Theme.settingsControlWidth)
                }
            }
            task("Choose a language you are not going to speak, then dictate a sentence in your own.")
            if let last = tour.last, last.translated { compare("What was heard", last.raw, "What Tacet wrote", last.text) }
            field
        case .edit:
            say("Select the text below, hold the key and say:", "Make it shorter.")
            editor
        case .translateSelection:
            say("Select the text again and say:", "Translate into Spanish.")
            editor
        case .paste:
            SoftCard {
                SoftRow("Paste automatically", subtitle: "Keeps your existing clipboard. Turn off to copy dictations for manual pasting.") {
                    Toggle("Paste automatically", isOn: $settings.pasteAutomatically).labelsHidden().toggleStyle(.switch)
                }
            }
            task("Turn pasting off, dictate a phrase, then press ⌘V in the field. Your earlier setting returns after this step.")
            field
        case .history:
            task("Every dictation is kept in History: the original and the corrected text, the recording, and anything that could not be pasted. You can listen, copy or recognise again.")
            Button {
                AppWindows.shared.showHistory()
            } label: { Label("Open History", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(SoftProminentButtonStyle())
        case .indicator:
            SoftCard(title: "Floating indicator", systemImage: "sparkles") {
                SoftRow("Theme") {
                    SettingsPicker(title: "Theme", selection: $settings.indicatorTheme,
                                   options: IndicatorTheme.allCases.map { .init($0.rawValue, $0.title) })
                        .frame(width: Theme.settingsControlWidth)
                }
                SoftDivider()
                SoftRow("Position", subtitle: "Where the indicator appears") {
                    SettingsPicker(title: "Position", selection: $settings.indicatorPosition,
                                   options: [.init("top", "Top"), .init("bottom", "Bottom")])
                        .frame(width: Theme.settingsControlWidth)
                }
                SoftDivider()
                SoftRow("Sounds", subtitle: "Short Tacet cues for start, success and errors") {
                    Toggle("Sounds", isOn: $settings.playSounds).labelsHidden().toggleStyle(.switch)
                }
                SoftDivider()
                SoftRow("Lower background audio", subtitle: "Turns down other audio while you dictate and restores it when you stop.") {
                    Toggle("Lower background audio", isOn: $settings.quietBackgroundAudio).labelsHidden().toggleStyle(.switch)
                }
            }
            Button {
                HUDController.shared.preview()
                tour.note(.indicator)
            } label: { Label("Show the indicator", systemImage: "eye") }
                .buttonStyle(SoftProminentButtonStyle())
        }
    }

    // MARK: Pieces

    private func say(_ lead: LocalizedStringKey, _ phrase: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lead).font(.system(size: 12.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "quote.opening").foregroundStyle(Theme.accent)
                Text(phrase).font(.system(size: 17, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Hold \(keyName), speak, release.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.accent.opacity(0.10)))
    }

    private func task(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.point.right.fill").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compare(_ leftTitle: LocalizedStringKey, _ left: String, _ rightTitle: LocalizedStringKey, _ right: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach([(leftTitle, left, false), (rightTitle, right, true)], id: \.1) { title, text, strong in
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(strong ? Theme.accent : .secondary)
                    Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.trackFill(scheme)))
            }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Practice field").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $practice)
                .font(.system(size: 14))
                .focused($practiceFocused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 96, maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.trackFill(scheme)))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .stroke(practiceFocused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            field
            HStack {
                Button {
                    practiceFocused = true
                    DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                } label: { Label("Select the text", systemImage: "text.cursor") }
                    .buttonStyle(SoftButtonStyle())
                Button("Restore the sample") { practice = Self.sample }
                    .buttonStyle(SoftButtonStyle())
            }
        }
    }

    // MARK: Step lifecycle

    private func enter(_ step: Onboarding.Step) {
        switch step {
        case .edit, .translateSelection: practice = Self.sample
        case .translate:
            practice = ""
            savedOutputLanguage = settings.outputLanguage
        case .paste:
            practice = ""
            savedPaste = settings.pasteAutomatically
        default: practice = ""
        }
        if step != .key && step != .history && step != .indicator { practiceFocused = true }
    }

    /// Settings changed only for practice go back to what the user had.
    /// Налаштування, змінені лише для тренування, повертаються до того, що було в користувача.
    private func leave(_ step: Onboarding.Step) {
        if step == .translate, let saved = savedOutputLanguage {
            settings.outputLanguage = saved
            savedOutputLanguage = nil
        }
        if step == .paste, let saved = savedPaste {
            settings.pasteAutomatically = saved
            savedPaste = nil
        }
    }

    private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            openPrivacyPane("Microphone")
            return
        }
        Task { micGranted = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    private func openPrivacyPane(_ category: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(category)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The key as the recorder shows it, e.g. "Right ⌘". / Клавіша так, як її показує поле запису, напр. «Right ⌘».
    private var keyName: String {
        HotkeyFormat.title(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers, label: settings.hotkeyLabel)
    }

    // MARK: Texts

    private static var sample: String {
        String(localized: "Our team meeting has been moved from Monday to Thursday because several people are travelling, so please update your calendars and let me know if the new time does not work for you.")
    }

    private func title(_ step: Onboarding.Step) -> LocalizedStringKey {
        switch step {
        case .key: "The dictation key"
        case .dictate: "Dictate"
        case .correct: "Automatic correction"
        case .languages: "Any language, no switching"
        case .translate: "Speak one language, write another"
        case .edit: "Edit by voice"
        case .translateSelection: "Translate a selection"
        case .paste: "Where the text goes"
        case .history: "History"
        case .indicator: "Indicator and sounds"
        }
    }

    private func summary(_ step: Onboarding.Step) -> LocalizedStringKey {
        switch step {
        case .key: "Tacet lives in the menu bar and listens only while you hold one key. Allow the microphone and pasting, then try the key."
        case .dictate: "Put the cursor where you want the text, hold the key, speak and release. The text appears where the cursor is."
        case .correct: "Tacet writes what you meant, not every sound you made: it drops slips and fillers and adds punctuation and capitals."
        case .languages: "Tacet works out the language of each dictation by itself."
        case .translate: "With an output language set, you speak your own language and Tacet inserts the translation."
        case .edit: "Select text anywhere and tell Tacet what to do with it. Up to 1000 words at a time."
        case .translateSelection: "The same gesture translates: select, hold the key, name the language."
        case .paste: "By default Tacet pastes into the active field and keeps your clipboard. You can have it copy instead."
        case .history: "Nothing you dictate gets lost."
        case .indicator: "Choose how Tacet shows and sounds that it is listening."
        }
    }

    private func waiting(_ step: Onboarding.Step) -> LocalizedStringKey {
        switch step {
        case .key: "Waiting for you to press the key"
        case .history: "Waiting for you to open History"
        case .indicator: "Waiting for you to show the indicator"
        case .paste: "Waiting for a dictation with pasting off"
        case .edit, .translateSelection: "Waiting for a voice edit of the selected text"
        case .translate: "Waiting for a translated dictation"
        case .languages: "Waiting for two languages"
        default: "Waiting for your dictation"
        }
    }
}
