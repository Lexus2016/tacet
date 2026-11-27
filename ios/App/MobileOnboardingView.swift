import SwiftUI
import UIKit

enum TourStyle {
    static let accentStart = Color(red: 0.17, green: 0.55, blue: 0.81)
    static let accentEnd = Color(red: 0.08, green: 0.33, blue: 0.67)
}

private let privacyURL = URL(string: "https://lexus2016.github.io/tacet/privacy.html")!

/// The consent screen: audio and selected text go to third-party AI models through Tacet, and nothing is
/// sent before the user agrees (App Store Review Guideline 5.1.2(i)).
/// Екран згоди: звук і виділений текст через Tacet потрапляють до сторонніх моделей ШІ, і до згоди
/// нічого не надсилається.
struct MobileConsentView: View {
    var onAgree: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(TourStyle.accentStart)
                        .padding(.top, 28)
                    Text("Before you start")
                        .font(.system(size: 32, weight: .bold))
                    Text("Tacet Ensemble sends what you dictate to AI models run by other companies, and gives you the corrected text back.")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        row("waveform", "Your voice", "The audio of each dictation, while it is recognised.")
                        row("text.alignleft", "Your text", "For correction, translation and voice edits: the dictated text and, for a voice edit, the passage you selected.")
                        row("building.2", "Who receives it", "OpenRouter, Groq, Together, Amazon Web Services (Bedrock), Cerebras and Ollama. They act on our behalf and do not train on your data.")
                        row("iphone", "What stays here", "Typing, word suggestions and Tacet Solo dictation run on your iPhone and send nothing.")
                    }
                    .padding(18)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("Our server does not store audio or text. You can withdraw your consent at any time in the app, and delete your account.")
                        .font(.system(size: 15.5))
                        .foregroundStyle(.secondary)
                    Link(destination: privacyURL) {
                        Label("Read the privacy policy", systemImage: "arrow.up.right.square")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            VStack(spacing: 8) {
                Button(action: onAgree) {
                    Text("I agree").font(.system(size: 19, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not now", action: onDecline)
                    .font(.system(size: 17))
                Text("Without consent, voice features stay off. Typing on the Tacet keyboard keeps working.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func row(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(TourStyle.accentStart).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(text).font(.system(size: 15.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The first-run tour on the iPhone: nine actions, each finished by doing it in a practice field.
/// Знайомство на iPhone: дев'ять дій, кожну завершують, виконавши її в тренувальному полі.
struct MobileOnboardingView: View {
    @ObservedObject var tour: MobileOnboarding
    @ObservedObject var session: MobileDictationSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MobilePreferences.translateToLayout) private var translatesToLayout = false
    @State private var practice = ""
    @State private var selectAll = 0
    @State private var savedTranslation: Bool?
    @State private var canSkip = false
    @FocusState private var focused: Bool

    private static let sample = "hello, this is a quick note i wrote yesterday it is a bit long and could be shorter"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title(tour.step)).font(.system(size: 28, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail(tour.step)).font(.system(size: 16.5)).foregroundStyle(.secondary)
                    scrollContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // The phrase to say and the practice field stay above the footer, so the keyboard never hides them.
            // Фраза, яку треба сказати, і тренувальне поле лишаються над підвалом, тож клавіатура їх не закриває.
            pinnedContent
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            footer
        }
        .background(Color(.systemBackground))
        .onAppear {
            tour.screenChanged(visible: true)
            tour.configureTyping(layouts: (try? DictationBridge.keyboardLayouts()) ?? KeyboardLayout.defaults)
            tour.refreshKeyboard()
            enter(tour.step)
        }
        // Only the App Review account is told it may skip the tour; nobody else sees the button.
        // Лише акаунту рецензента App Review дозволено пропустити знайомство; решта кнопки не бачить.
        .task {
            canSkip = (try? await AccountPlansClient.request())?.review == true
        }
        .onDisappear {
            leave(tour.step)
            tour.screenChanged(visible: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { tour.refreshKeyboard() }
        }
        .onChange(of: session.deadline) { _, deadline in if deadline != nil { tour.note(.session) } }
        .onChange(of: session.delivery) { _, delivery in if let delivery { tour.delivered(delivery) } }
        .onChange(of: practice) { _, text in tour.practiceChanged(text) }
        .onChange(of: tour.step) { old, new in
            leave(old)
            enter(new)
        }
    }

    // MARK: Layout

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STEP \(tour.step.rawValue + 1) OF \(MobileOnboarding.Step.allCases.count)")
                .font(.system(size: 13, weight: .bold)).tracking(1.2)
                .foregroundStyle(TourStyle.accentStart)
            GeometryReader { proxy in
                let total = CGFloat(MobileOnboarding.Step.allCases.count)
                let done = CGFloat(tour.step.rawValue) + (tour.canContinue ? 1 : 0.4)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(LinearGradient(colors: [TourStyle.accentStart, TourStyle.accentEnd], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * min(1, done / total))
                        .animation(.easeOut(duration: 0.3), value: done)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Group {
                if tour.canContinue {
                    Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(waiting(tour.step)) }
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 15.5, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if tour.step.rawValue > 0 {
                    Button("Back") { tour.back() }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Button { tour.advance() } label: {
                    Text(tour.isLast ? "Finish" : "Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!tour.canContinue)
            }
            if canSkip {
                Button("Skip the tour") { tour.skip() }.font(.system(size: 15))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var scrollContent: some View {
        switch tour.step {
        case .keyboard:
            card {
                numbered(1, "Open Settings, then General, Keyboard, Keyboards.")
                numbered(2, "Tap Add New Keyboard and choose Tacet.")
                numbered(3, "Tap Tacet and turn on Allow Full Access. Voice features need it; typing does not.")
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { Label("Open Settings", systemImage: "gearshape") }
                .buttonStyle(.bordered).controlSize(.large)
        case .session:
            card {
                Text("Tacet keeps the microphone ready for 15 minutes at a time, so voice works the moment you tap it in any app.")
                    .font(.system(size: 16.5))
            }
            Button {
                Task { _ = await session.enableConfigured() }
            } label: {
                if session.working { HStack { ProgressView().controlSize(.small); Text("Preparing session…") } }
                else { Label("Start the session", systemImage: "mic") }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let message = session.message { Text(message).foregroundStyle(.red).font(.system(size: 15.5)) }
        case .translate:
            card {
                Toggle("Translate to the keyboard language", isOn: $translatesToLayout).font(.system(size: 17, weight: .medium))
                Text("Switch the Tacet keyboard to another language with the globe key, then dictate a sentence in your own language. The text comes out in the keyboard’s language.")
                    .font(.system(size: 15.5)).foregroundStyle(.secondary)
            }
        case .typing:
            card {
                Text("Typing is built in too. The word below has a typo: tap it and pick the suggestion Tacet offers above the keyboard.")
                    .font(.system(size: 16.5))
            }
        case .dictate, .correct, .languages, .edit, .translateSelection:
            EmptyView()
        }
    }

    @ViewBuilder
    private var pinnedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tour.step {
            case .keyboard, .session:
                EmptyView()
            case .dictate:
                say("Tap the field, switch to the Tacet keyboard with the globe key, tap the microphone and say:", "I will send the report on Friday morning.")
                field
            case .correct:
                say("Say it the way people really talk, with a slip:", "Let’s meet on Tuesday, no, on Wednesday at three.")
                if let last = tour.last { compare("What was heard", last.raw, "What Tacet wrote", last.text) }
                field
            case .languages:
                sayTwo("Dictate these two phrases one after the other, each in its own dictation. Nothing to switch.", "Good morning!", "¡Buenos días!")
                if !tour.languages.isEmpty {
                    HStack(spacing: 8) {
                        Text("Heard so far:").foregroundStyle(.secondary)
                        ForEach(tour.languages, id: \.self) { code in
                            Text(code.uppercased()).font(.system(size: 14, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(TourStyle.accentStart.opacity(0.16)))
                        }
                    }
                }
                field
            case .translate:
                if let last = tour.last, last.translated { compare("What was heard", last.raw, "What Tacet wrote", last.text) }
                field
            case .edit:
                say("Select the text below, tap the microphone and say:", "Make it shorter.")
                editor
            case .translateSelection:
                say("Select the text again and say:", "Translate into Spanish.")
                editor
            case .typing:
                field
            }
        }
    }

    // MARK: Pieces

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Practice field").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.secondary)
            PracticeTextView(text: $practice, selectAll: selectAll, focus: false)
                .frame(minHeight: 76, maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TourStyle.accentStart.opacity(0.6), lineWidth: 1.5))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            field
            HStack {
                Button { selectAll += 1 } label: { Label("Select the text", systemImage: "text.cursor") }
                    .buttonStyle(.bordered)
                Button("Restore the sample") { practice = Self.sample }.buttonStyle(.bordered)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func numbered(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(TourStyle.accentStart))
            Text(text).font(.system(size: 16.5))
        }
    }

    private func say(_ lead: LocalizedStringKey, _ phrase: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lead).font(.system(size: 15)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "quote.opening").foregroundStyle(TourStyle.accentStart).padding(.top, 5)
                Text(phrase).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TourStyle.accentStart.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(
            LinearGradient(colors: [TourStyle.accentStart, TourStyle.accentEnd.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
    }

    private func sayTwo(_ lead: LocalizedStringKey, _ first: LocalizedStringKey, _ second: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lead).font(.system(size: 16.5)).foregroundStyle(.secondary)
            ForEach([(1, first), (2, second)], id: \.0) { number, phrase in
                HStack(spacing: 12) {
                    Text("\(number)").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(TourStyle.accentStart))
                    Text(phrase).font(.system(size: 24, weight: .bold))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TourStyle.accentStart.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(TourStyle.accentStart.opacity(0.6), lineWidth: 1.5))
    }

    private func compare(_ leftTitle: LocalizedStringKey, _ left: String, _ rightTitle: LocalizedStringKey, _ right: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(leftTitle).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.secondary)
                Text(left).font(.system(size: 17))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(rightTitle).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(TourStyle.accentStart)
                Text(right).font(.system(size: 17, weight: .semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Step lifecycle

    private func enter(_ step: MobileOnboarding.Step) {
        switch step {
        case .edit, .translateSelection: practice = Self.sample
        case .translate:
            practice = ""
            savedTranslation = translatesToLayout
        case .typing: practice = tour.typoSample
        default: practice = ""
        }
    }

    /// The setting the user had before the translate step returns when the step ends.
    /// Налаштування, яке було до кроку з перекладом, повертається після нього.
    private func leave(_ step: MobileOnboarding.Step) {
        if step == .translate, let saved = savedTranslation {
            translatesToLayout = saved
            savedTranslation = nil
        }
    }

    // MARK: Texts

    private func title(_ step: MobileOnboarding.Step) -> LocalizedStringKey {
        switch step {
        case .keyboard: "Turn on the keyboard"
        case .session: "Start a session"
        case .dictate: "Dictate"
        case .correct: "Automatic correction"
        case .languages: "Any language, no switching"
        case .translate: "Speak one language, write another"
        case .edit: "Edit by voice"
        case .translateSelection: "Translate a selection"
        case .typing: "Typing and suggestions"
        }
    }

    private func detail(_ step: MobileOnboarding.Step) -> LocalizedStringKey {
        switch step {
        case .keyboard: "Tacet is a keyboard: it works in every app. Turn it on once."
        case .session: "Dictation needs a short session. You can start one any time from the keyboard."
        case .dictate: "The text appears where the cursor is."
        case .correct: "Tacet writes what you meant, not every sound you made: it drops slips and fillers and adds punctuation and capitals."
        case .languages: "Tacet works out the language of each dictation by itself."
        case .translate: "With translation on, you speak your own language and Tacet inserts the translation."
        case .edit: "Select text anywhere and tell Tacet what to do with it. Up to 1000 words at a time."
        case .translateSelection: "The same gesture translates: select, tap the microphone, name the language."
        case .typing: "Word suggestions and typo correction work on the device, without a connection."
        }
    }

    private func waiting(_ step: MobileOnboarding.Step) -> LocalizedStringKey {
        switch step {
        case .keyboard: "Waiting for the keyboard to be turned on"
        case .session: "Waiting for the session"
        case .dictate: "Waiting for your dictation"
        case .correct: tour.attempts > 0 ? "Try once more, with a slip in the phrase" : "Waiting for your dictation"
        case .languages: tour.attempts > 0 ? "Now dictate the second phrase, in another language." : "Waiting for your first phrase"
        case .translate: tour.attempts > 0 ? "That phrase was not translated. Switch the keyboard to a different language." : "Waiting for a translated dictation"
        case .edit, .translateSelection: "Waiting for a voice edit of the selected text"
        case .typing: "Waiting for you to pick the suggestion"
        }
    }
}

/// A text view the tour can read and select in. A plain UITextView so the Tacet keyboard types into it.
/// Текстове поле, яке знайомство може читати й виділяти. Звичайний UITextView, щоб у нього друкувала клавіатура Tacet.
struct PracticeTextView: UIViewRepresentable {
    @Binding var text: String
    var selectAll: Int
    var focus: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .systemFont(ofSize: 20)
        view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if context.coordinator.selectAllCount != selectAll {
            context.coordinator.selectAllCount = selectAll
            view.becomeFirstResponder()
            view.selectAll(nil)
        }
        if focus, !context.coordinator.focused {
            context.coordinator.focused = true
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !focus { context.coordinator.focused = false }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PracticeTextView
        var selectAllCount: Int
        var focused = false
        init(_ parent: PracticeTextView) { self.parent = parent; selectAllCount = parent.selectAll }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
    }
}
