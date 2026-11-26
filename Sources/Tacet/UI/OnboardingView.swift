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
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        stepBody
                            .environment(\.largeControls, true)
                            .controlSize(.large)
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 26)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .background {
            ZStack {
                SoftWindowBackground()
                // A vivid glow gives the first screens depth and energy.
                // Яскраве сяйво додає перших екранів глибини й енергії.
                RadialGradient(colors: [Theme.accentStart.opacity(scheme == .dark ? 0.38 : 0.22), .clear],
                               center: .topTrailing, startRadius: 20, endRadius: 560)
                RadialGradient(colors: [Self.violet.opacity(scheme == .dark ? 0.30 : 0.16), .clear],
                               center: .bottomLeading, startRadius: 20, endRadius: 520)
            }
            .ignoresSafeArea()
        }
        .onAppear { enter(tour.step) }
        .onChange(of: tour.inbound) { _, item in
            guard let item else { return }
            if item.replacesAll || practice.isEmpty {
                practice = item.text
            } else {
                practice += (practice.hasSuffix(" ") || practice.hasSuffix("\n") ? "" : " ") + item.text
            }
            practiceFocused = true
        }
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
                .font(.system(size: 28, weight: .heavy))
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            Text("Ten short steps. Each one is something you do, not something you read.")
                .font(.system(size: 16.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            ForEach(Onboarding.Step.allCases) { step in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(tour.finished.contains(step) ? Theme.success
                                  : step == tour.step ? Theme.accent : Theme.trackFill(scheme))
                            .frame(width: 32, height: 32)
                        if tour.finished.contains(step) {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(step == tour.step ? .white : .secondary)
                        }
                    }
                    Text(title(step))
                        .font(.system(size: 17.5, weight: step == tour.step ? .semibold : .regular))
                        .foregroundStyle(step == tour.step ? .primary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(step == tour.step ? Theme.accent.opacity(scheme == .dark ? 0.22 : 0.14) : .clear))
                .animation(.easeOut(duration: 0.2), value: tour.step)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 28)
        .frame(width: 340, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            progressBar
            Text("Step \(tour.step.rawValue + 1) of \(Onboarding.Step.allCases.count)")
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Theme.accentStart, Self.violet], startPoint: .leading, endPoint: .trailing))
                .textCase(.uppercase)
                .tracking(1.2)
            Text(title(tour.step))
                .font(.system(size: 44, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary(tour.step))
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let violet = Color(red: 0.52, green: 0.38, blue: 0.98)

    /// Overall progress: every finished step plus the current one once it is done.
    /// Загальний прогрес: кожен завершений крок і поточний, щойно його виконано.
    private var progressBar: some View {
        let total = Double(Onboarding.Step.allCases.count)
        let value = Double(tour.finished.count)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.trackFill(scheme))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accentStart, Self.violet], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, proxy.size.width * value / total))
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: tour.finished.count)
            }
        }
        .frame(height: 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if tour.canContinue {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    .font(.system(size: 18, weight: .semibold))
            } else {
                Label(waiting(tour.step, attempts: tour.attempts), systemImage: "circle.dotted").foregroundStyle(.secondary)
                    .font(.system(size: 17.5))
            }
            Spacer()
            if tour.step != .key {
                Button("Back") { tour.back() }.buttonStyle(SoftButtonStyle(large: true))
            }
            Button(tour.isLast ? "Start using Tacet" : "Continue") { tour.advance() }
                .buttonStyle(SoftProminentButtonStyle(large: true))
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
            sayTwo("Dictate these two phrases one after the other, each in its own dictation. Nothing to switch.",
                   "Good morning!", "¡Buenos días!")
            if settings.languageMode != "auto" {
                HStack {
                    Text("A fixed language is selected, so Tacet will not detect it.").font(.system(size: 17.5))
                    Button("Detect automatically") { settings.languageMode = "auto" }.buttonStyle(SoftButtonStyle())
                }
            }
            if !tour.languages.isEmpty {
                HStack(spacing: 8) {
                    Text("Heard so far:").font(.system(size: 17.5)).foregroundStyle(.secondary)
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
            Text(lead).font(.system(size: 17.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "quote.opening").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.accentStart)
                Text(phrase).font(.system(size: 32, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Hold \(keyName), speak, release.").font(.system(size: 16.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(spotlight)
    }

    private func sayTwo(_ lead: LocalizedStringKey, _ first: LocalizedStringKey, _ second: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lead).font(.system(size: 17.5)).foregroundStyle(.secondary)
            ForEach([(1, first), (2, second)], id: \.0) { number, phrase in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(number)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(LinearGradient(colors: [Theme.accentStart, Self.violet], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    Text(phrase).font(.system(size: 32, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Hold \(keyName), speak, release.").font(.system(size: 16.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(spotlight)
    }

    /// The card behind the phrase to say: tinted, with a bright gradient edge.
    /// Картка за фразою, яку треба сказати: з відтінком і яскравим градієнтним краєм.
    private var spotlight: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Theme.accentStart.opacity(scheme == .dark ? 0.26 : 0.16),
                                          Self.violet.opacity(scheme == .dark ? 0.22 : 0.12)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.stroke(LinearGradient(colors: [Theme.accentStart.opacity(0.9), Self.violet.opacity(0.9)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
            .shadow(color: Self.violet.opacity(scheme == .dark ? 0.30 : 0.18), radius: 18, y: 6)
    }

    private func task(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.point.right.fill").font(.system(size: 22)).foregroundStyle(Theme.accentStart)
            Text(text).font(.system(size: 19.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compare(_ leftTitle: LocalizedStringKey, _ left: String, _ rightTitle: LocalizedStringKey, _ right: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach([(leftTitle, left, false), (rightTitle, right, true)], id: \.1) { title, text, strong in
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(strong ? Theme.accent : .secondary)
                    Text(text).font(.system(size: 18)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.trackFill(scheme)))
            }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Practice field").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $practice)
                .font(.system(size: 20.5))
                .focused($practiceFocused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 150, maxHeight: 230)
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

    private func waiting(_ step: Onboarding.Step, attempts: Int) -> LocalizedStringKey {
        switch step {
        case .key: "Waiting for you to press the key"
        case .history: "Waiting for you to open History"
        case .indicator: "Waiting for you to show the indicator"
        case .paste: "Waiting for a dictation with pasting off"
        case .edit, .translateSelection: "Waiting for a voice edit of the selected text"
        case .translate:
            attempts > 0 ? "That phrase was not translated. Choose a language different from the one you speak." : "Waiting for a translated dictation"
        case .languages:
            attempts > 0 ? "Now dictate the second phrase, in another language." : "Waiting for your first phrase"
        default: "Waiting for your dictation"
        }
    }
}
