import UIKit

/// A letter key drawn as a plain view with a label. `UIButton.Configuration` re-renders its
/// background and attributed title on every highlight and title change; a Time Profiler run on an
/// iPhone 15 Pro put that system work at ~10 ms of main-thread time per keystroke.
/// Літерна клавіша: звичайна view з написом. `UIButton.Configuration` перемальовує тло й
/// атрибутований заголовок при кожному натисканні та зміні тексту; запис Time Profiler на
/// iPhone 15 Pro показав ~10 мс головного потоку на кожне натискання для цієї системної роботи.
private final class TypingKey: UIButton {
    private let face = UIView()
    var faceInset: CGFloat {
        didSet { if faceInset != oldValue { setNeedsLayout() } }
    }

    init(title: String, color: UIColor, inset: CGFloat) {
        faceInset = inset
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        face.backgroundColor = color
        face.layer.cornerRadius = 7
        face.layer.cornerCurve = .continuous
        insertSubview(face, at: 0)
        setTitle(title, for: .normal)
        setTitleColor(.label, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 23, weight: .regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds.insetBy(dx: 0, dy: faceInset)
        sendSubviewToBack(face)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -3, dy: 0).contains(point)
    }
}

/// A prediction slot whose title sits at a fixed height in the strip, like the system keyboard's.
/// Комірка підказки, текст якої стоїть на сталій висоті смуги, як у системній клавіатурі.
private final class SuggestionKey: UIButton {
    var titleCenter: CGFloat? { didSet { setNeedsLayout() } }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        var rect = super.titleRect(forContentRect: contentRect)
        if let titleCenter { rect.origin.y = titleCenter - rect.height / 2 }
        // Keep a little air next to the dividers; a long word shrinks instead of touching them.
        // Лишаємо трохи повітря біля роздільників; довге слово зменшується, а не торкається їх.
        let widest = contentRect.width - 10
        if rect.width > widest {
            rect.origin.x = contentRect.minX + 5
            rect.size.width = max(0, widest)
        }
        return rect
    }
}

/// Animated bars shown in the strip while dictation records. The keyboard has no microphone
/// access, so the motion signals "recording" and does not follow the actual input level.
/// Анімовані смужки в смузі під час запису диктування. Клавіатура не має доступу до мікрофона,
/// тож рух означає «йде запис» і не повторює справжній рівень звуку.
private final class DictationWave: UIView {
    var centerLine: CGFloat? { didSet { setNeedsLayout() } }
    var isActive = false {
        didSet { if isActive != oldValue { animate() } }
    }
    private var bars: [CALayer] = []
    private var builtWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = max(0, Int((bounds.width - 16) / 6))
        if builtWidth != bounds.width || bars.count != count {
            builtWidth = bounds.width
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<count).map { _ in
                let bar = CALayer()
                bar.cornerRadius = 1.5
                layer.addSublayer(bar)
                return bar
            }
        }
        let middle = centerLine ?? bounds.midY
        let left = (bounds.width - CGFloat(count) * 6 + 3) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = UIColor.label.withAlphaComponent(0.72).cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: 16)
            bar.position = CGPoint(x: left + CGFloat(index) * 6 + 1.5, y: middle)
        }
        CATransaction.commit()
        animate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animate()
    }

    private func animate() {
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            // A fixed, uneven pattern: neighbouring bars differ in height and tempo.
            // Сталий нерівний малюнок: сусідні смужки різняться висотою й темпом.
            let low = 0.18 + 0.12 * Double((index * 7) % 5) / 4
            let high = 0.55 + 0.45 * Double((index * 11) % 7) / 6
            guard isActive, window != nil, !UIAccessibility.isReduceMotionEnabled else {
                bar.transform = CATransform3DMakeScale(1, isActive ? (low + high) / 2 : low, 1)
                continue
            }
            let pulse = CABasicAnimation(keyPath: "transform.scale.y")
            pulse.fromValue = low
            pulse.toValue = high
            pulse.duration = 0.28 + 0.07 * Double((index * 5) % 6)
            pulse.timeOffset = 0.05 * Double((index * 3) % 8)
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            bar.add(pulse, forKey: "pulse")
        }
    }
}

final class KeyboardController: UIInputViewController {
    // Measured against the system keyboard on the same iPhone screen: rows repeat every 54 pt and sit
    // flush with the view's bottom edge; the strip above them is 50 pt.
    //
    // Known iOS 26/27 defect (Apple Developer Forums thread 843093, FB24460699): after a switch from
    // Apple's letter keyboard, or after leaving and re-entering the host app with the keyboard up, the
    // host adds a 17 pt inset above every third-party keyboard. The extension's view, window and safe
    // area stay identical, so the inset can be neither removed nor detected from here, and nothing may
    // be drawn into it. The strip's content therefore sits 3 pt above the strip's own middle: that is
    // 3 pt high without the inset and 3 pt low with it, instead of 6 pt off in one of the two states.
    //
    // Заміряно відносно системної клавіатури на тому самому екрані iPhone: крок рядів 54 pt, нижній
    // ряд — впритул до низу view; смуга над рядами — 50 pt.
    //
    // Відомий дефект iOS 26/27 (Apple Developer Forums, тема 843093, FB24460699): після перемикання з
    // літерної клавіатури Apple або після виходу із застосунку й повернення з відкритою клавіатурою
    // система додає над будь-якою сторонньою клавіатурою відступ 17 pt. View, вікно й безпечна зона
    // розширення лишаються тими самими, тож відступ не можна ні прибрати, ні виявити, і малювати в ньому
    // не можна. Тому вміст смуги стоїть на 3 pt вище її власної середини: без відступу це на 3 pt
    // зависоко, з відступом — на 3 pt занизько, а не на 6 pt мимо в одному з двох станів.
    private enum PortraitMetrics {
        static let height: CGFloat = 255
        static let top: CGFloat = 50
        static let gap: CGFloat = 11
        static let stripCenter: CGFloat = 19.5
    }

    private enum Strip {
        static let font = UIFont.systemFont(ofSize: 21, weight: .regular)
        static let text = UIColor.label.withAlphaComponent(0.72)
        static let micWidth: CGFloat = 44
    }

    private enum LandscapeMetrics {
        static let height: CGFloat = 229
        static let top: CGFloat = 27
        static let gap: CGFloat = 6
    }

    private enum Palette {
        static let key = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : .white
        }
        static let modifier = UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 0.21 : 0.84, alpha: 1)
        }
        static let keyPreview = UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 0.32 : 0.96, alpha: 1)
        }
        static let accent = UIColor(red: 0.18, green: 0.42, blue: 0.72, alpha: 1)
        static let caption = UIColor.secondaryLabel
        static let micIdle = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.66, blue: 0.98, alpha: 1) : accent
        }
    }

    private struct Field: Equatable {
        let document: UUID
        let before: String?
        let after: String?
        let selection: String?

        init(_ proxy: UITextDocumentProxy) {
            document = proxy.documentIdentifier
            before = proxy.documentContextBeforeInput
            after = proxy.documentContextAfterInput
            selection = proxy.selectedText
        }
    }

    private struct Request {
        enum State: Equatable { case starting, recording, finishing }
        let session: UUID
        let id: UUID
        let field: Field
        var state = State.starting
        var expires = Date().addingTimeInterval(4)
    }

    private struct WakeRequest {
        let field: Field
        let layout: KeyboardLayout
        let expires: Date
    }

    private struct SuggestionContext: Equatable {
        let field: Field
        let layout: KeyboardLayout
        let word: KeyboardWord
    }

    private struct Suggestions: Equatable {
        let context: SuggestionContext
        let choices: [String]
    }

    private struct CheckerResult: Equatable {
        let misspelled: Bool
        let words: [String]
    }

    private struct Trackpad {
        let document: UUID
        var anchor: CGPoint
    }

    private struct DictationButtonState: Equatable {
        let request: Request.State?
        let hasSession: Bool
        let local: Bool
    }

    private static var wakeRequest: WakeRequest?

    private enum KeyPage { case letters, numbers, extended }

    private let dictationButton = UIButton(configuration: .plain())
    private let dictationWave = DictationWave()
    private let micDivider = UIView()
    private let localBadge = UIView()
    private var stripCenter: CGFloat? = PortraitMetrics.stripCenter
    private let statusLabel = UILabel()
    private let keyPreview = UILabel()
    private let suggestionBar = UIStackView()
    private let pinyinBar = KeyboardPinyinBar()
    private let keys = UIStackView()
    private let globe = UIButton(configuration: .filled())
    private var layoutPicker: UIStackView?
    private var keyboardHeight: NSLayoutConstraint?
    private var rowsHeightConstraint: NSLayoutConstraint?
    private var stripHeight = PortraitMetrics.top
    private var dividerCenters: [NSLayoutConstraint] = []
    private var bottomInset: NSLayoutConstraint?
    private var suggestionBottom: NSLayoutConstraint?
    private var rowPadding = PortraitMetrics.gap / 2
    private var shiftButton: UIButton?
    private var letterButtons: [(UIButton, KeyboardLayout.Key)] = []
    private var feedback: UIImpactFeedbackGenerator?
    private let checker = UITextChecker()
    private let lexicon = KeyboardCompletionLexicon()
    private let pinyinLexicon = KeyboardPinyinLexicon()
    private lazy var dictionaries = UITextChecker.availableLanguages
    private var suggestionDividers: [UIView] = []
    private var suggestions: Suggestions?
    private var suggestionRefresh: Task<Void, Never>?
    private var correctionRefresh: Task<Void, Never>?
    private var suggestionGeneration = 0
    private var checkerCache: [String: CheckerResult] = [:]
    private var checkerWarmup: Task<Void, Never>?
    private var warmedLayouts: Set<KeyboardLayout> = []
    private var pressedSuggestion: (index: Int, options: Suggestions)?
    private var pinyin = KeyboardPinyinComposition()
    private var pinyinField: Field?
    private var pinyinCandidates: [String] = []
    private var pinyinRefresh: Task<Void, Never>?
    private var touchedKeys: Set<ObjectIdentifier> = []
    private var lastEdit = ContinuousClock.now - .seconds(1)
    private var deleteRepeat: Task<Void, Never>?
    private var deletedOnTouchDown = false
    private var heldLetters: [UIButton] = []
    private var committedEarly: Set<ObjectIdentifier> = []
    private var trackpad: Trackpad?
    private var verticalCursorMove: Task<Void, Never>?
    private var renderedDictation: DictationButtonState?
    private weak var previewButton: UIButton?
    private weak var latestTouch: UIButton?
    private var previewStarted = ContinuousClock.now
    private var previewDismissal: Task<Void, Never>?
    private var status: DictationBridge.Status?
    private var pending: Request?
    private var pollTask: Task<Void, Never>?
    private var errorMessage: String?
    private var errorUntil = Date.distantPast
    private var enabledLayouts = KeyboardLayout.defaults
    private var layout = KeyboardLayout(rawValue: UserDefaults.standard.string(forKey: "tacet.keyboardLayout") ?? "en") ?? .english
    private var page = KeyPage.letters
    private var uppercase = false
    private var capitalization = KeyboardCapitalization.none
    private var manualShift = false
    private var caseRenderPending = false
    private var visible = false

    override func loadView() {
        let panel = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        // iOS can skip transparent pixels when routing touches to the keyboard extension.
        // iOS може не передавати розширенню клавіатури дотики до прозорих пікселів.
        panel.backgroundColor = UIColor(white: 0.5, alpha: 0.01)
        panel.isOpaque = false
        view = panel
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        refreshLayouts()
        prepareVocabulary()
        manualShift = false
        refreshAutomaticCase()
        buildKeys()
        // Rigid is the shortest, crispest impact; a high intensity keeps it firm.
        // Rigid — найкоротший і найчіткіший імпульс; висока інтенсивність робить його відчутним.
        if #available(iOS 17.5, *) {
            feedback = UIImpactFeedbackGenerator(style: .rigid, view: view)
        } else {
            feedback = UIImpactFeedbackGenerator(style: .rigid)
        }
        feedback?.prepare()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.poll()
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // System edge gestures hold back touches near the screen edges; keys there must react at once.
        // Системні жести країв екрана притримують дотики біля країв; клавіші там мають реагувати одразу.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        checkerWarmup?.cancel()
        clearPinyin()
        closeLayoutPicker()
        feedback = nil
        pollTask?.cancel()
        pollTask = nil
        cancelPending()
        clearPreview()
        touchedKeys.removeAll()
        heldLetters.removeAll()
        committedEarly.removeAll()
        endDeleteRepeat()
        endTrackpad()
        verticalCursorMove?.cancel()
        cancelSuggestionRefresh()
        pressedSuggestion = nil
        displaySuggestions(nil)
        super.viewWillDisappear(animated)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globe.isHidden = !needsInputModeSwitchKey
        let landscape = view.bounds.width > 480
        let padding = (landscape ? LandscapeMetrics.gap : PortraitMetrics.gap) / 2
        if rowPadding != padding {
            rowPadding = padding
            bottomInset?.constant = bottomInsetConstant(landscape: landscape)
            suggestionBottom?.constant = padding - 3
            for case let row as UIStackView in keys.arrangedSubviews {
                for case let key as UIButton in row.arrangedSubviews {
                    key.configuration?.background.backgroundInsets = keyBackgroundInsets
                    (key as? TypingKey)?.faceInset = padding
                }
            }
        }
        // Reserve the top strip even when there are no suggestions.
        // Резервуємо місце для верхньої смуги, навіть коли підказок немає.
        let height = landscape ? LandscapeMetrics.height : PortraitMetrics.height
        let rows = rowsHeight(landscape: landscape)
        if keyboardHeight?.constant != height { keyboardHeight?.constant = height }
        if rowsHeightConstraint?.constant != rows { rowsHeightConstraint?.constant = rows }
        let bottom = bottomInsetConstant(landscape: landscape)
        if bottomInset?.constant != bottom { bottomInset?.constant = bottom }
    }

    /// The rows keep their size and stay pinned to the bottom; the strip takes whatever height is left.
    /// Ряди зберігають розмір і притиснуті донизу; смуга забирає решту висоти.
    private func rowsHeight(landscape: Bool) -> CGFloat {
        landscape ? LandscapeMetrics.height - LandscapeMetrics.top + LandscapeMetrics.gap - 8
            : PortraitMetrics.height - PortraitMetrics.top + PortraitMetrics.gap
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Centre the strip's content in the strip's actual height, whatever height the system gave the view.
        // Центруємо вміст смуги за її фактичною висотою, яку б висоту система не дала view.
        let strip = keys.frame.minY + rowPadding
        placeLocalBadge()
        let center: CGFloat? = view.bounds.width > 480 ? nil
            : (strip * PortraitMetrics.stripCenter / PortraitMetrics.top * 2).rounded() / 2
        guard strip > 0, center != stripCenter || strip != stripHeight else { return }
        stripHeight = strip
        stripCenter = center
        placeLocalBadge()
        for case let slot as SuggestionKey in suggestionBar.arrangedSubviews { slot.titleCenter = center }
        dictationWave.centerLine = center
        for constraint in dividerCenters { constraint.constant = center ?? (strip - 3) / 2 }
        renderedDictation = nil
        renderState()
    }

    /// Runs on every layout pass: the button has no size when it is first rendered.
    /// Виконується на кожному проході розмітки: під час першого рендеру кнопка ще не має розміру.
    private func placeLocalBadge() {
        localBadge.frame = CGRect(x: dictationButton.bounds.midX + 7,
                                  y: (stripCenter ?? dictationButton.bounds.midY) - 13, width: 6, height: 6)
    }

    /// Portrait: the last row's key face ends at the view's bottom edge, like the system keyboard.
    /// Портрет: низ клавіш останнього ряду збігається з нижнім краєм view, як у системній клавіатурі.
    private func bottomInsetConstant(landscape: Bool) -> CGFloat {
        landscape ? rowPadding - 8 : rowPadding
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        clearPinyinIfFieldChanged()
        if let pending, pending.field != Field(textDocumentProxy) {
            cancelPending()
            showError(String(localized: "The text field changed. Dictate again here."))
        }
        refreshCaseAfterExternalChange()
        scheduleSuggestions()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        clearPinyinIfFieldChanged()
        refreshCaseAfterExternalChange()
        scheduleSuggestions()
    }

    private func configureView() {
        keys.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keys)
        let height = view.heightAnchor.constraint(equalToConstant: PortraitMetrics.height)
        // Just below required, so it never conflicts with the transient height the system applies while the keyboard appears.
        // Трохи нижче обов'язкового, щоб не конфліктувати з тимчасовою висотою, яку система задає під час появи клавіатури.
        height.priority = UILayoutPriority(999)
        height.isActive = true
        keyboardHeight = height
        let rows = keys.heightAnchor.constraint(equalToConstant: rowsHeight(landscape: false))
        let bottom = keys.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: bottomInsetConstant(landscape: false))
        rowsHeightConstraint = rows
        bottomInset = bottom
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6.5),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6.5),
            rows,
            bottom
        ])
        dictationButton.accessibilityIdentifier = "tacet-dictation"
        dictationButton.addTarget(self, action: #selector(dictationTapped), for: .touchUpInside)
        dictationButton.addTarget(self, action: #selector(keyFeedback), for: .touchDown)
        configureSuggestionBar()
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = Palette.caption
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.accessibilityIdentifier = "tacet-dictation-status"
        statusLabel.isHidden = true
        statusLabel.numberOfLines = 2
        statusLabel.backgroundColor = .clear
        statusLabel.layer.cornerRadius = 9
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: suggestionBar.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: dictationButton.trailingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: keys.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: suggestionBar.bottomAnchor)
        ])
        keyPreview.textAlignment = .center
        keyPreview.textColor = .label
        keyPreview.font = .systemFont(ofSize: 34, weight: .regular)
        keyPreview.backgroundColor = Palette.keyPreview
        keyPreview.layer.cornerRadius = 14
        keyPreview.clipsToBounds = true
        keyPreview.isAccessibilityElement = false
        keyPreview.isUserInteractionEnabled = false
        keyPreview.isHidden = true
        view.addSubview(keyPreview)
        keys.axis = .vertical
        keys.distribution = .fillEqually
        keys.spacing = 0
        globe.configuration?.image = UIImage(systemName: "globe")
        globe.configuration?.background.backgroundInsets = keyBackgroundInsets
        globe.configuration?.baseBackgroundColor = Palette.modifier
        globe.configuration?.baseForegroundColor = .label
        globe.accessibilityLabel = String(localized: "Switch keyboard")
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.addTarget(self, action: #selector(keyFeedback), for: .touchDown)
        let globeWidth = globe.widthAnchor.constraint(equalToConstant: 40)
        globeWidth.priority = .defaultHigh
        globeWidth.isActive = true
        renderState()
    }

    private func configureSuggestionBar() {
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.distribution = .fillEqually
        suggestionBar.spacing = 0
        suggestionBar.isHidden = true
        view.addSubview(suggestionBar)
        // Dictation lives at the strip's leading corner, where the system keyboard keeps its own control.
        // Диктування стоїть у лівому куті смуги, де системна клавіатура тримає власний елемент.
        dictationButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dictationButton)
        micDivider.isUserInteractionEnabled = false
        micDivider.isHidden = true
        micDivider.backgroundColor = Palette.caption.withAlphaComponent(0.22)
        micDivider.translatesAutoresizingMaskIntoConstraints = false
        dictationButton.addSubview(micDivider)
        dictationWave.isUserInteractionEnabled = false
        dictationWave.isHidden = true
        dictationWave.isAccessibilityElement = false
        dictationWave.centerLine = stripCenter
        dictationWave.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dictationWave)
        let bottom = suggestionBar.bottomAnchor.constraint(equalTo: keys.topAnchor, constant: rowPadding - 3)
        let micCenter = micDivider.centerYAnchor.constraint(equalTo: dictationButton.topAnchor,
                                                            constant: PortraitMetrics.stripCenter)
        dividerCenters.append(micCenter)
        suggestionBottom = bottom
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: view.topAnchor),
            bottom,
            suggestionBar.leadingAnchor.constraint(equalTo: dictationButton.trailingAnchor),
            dictationButton.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            dictationButton.topAnchor.constraint(equalTo: view.topAnchor),
            dictationButton.bottomAnchor.constraint(equalTo: suggestionBar.bottomAnchor),
            dictationButton.widthAnchor.constraint(equalToConstant: Strip.micWidth),
            micDivider.trailingAnchor.constraint(equalTo: dictationButton.trailingAnchor),
            micCenter,
            micDivider.heightAnchor.constraint(equalToConstant: 22),
            micDivider.widthAnchor.constraint(equalToConstant: 1),
            dictationWave.topAnchor.constraint(equalTo: suggestionBar.topAnchor),
            dictationWave.bottomAnchor.constraint(equalTo: suggestionBar.bottomAnchor),
            dictationWave.leadingAnchor.constraint(equalTo: suggestionBar.leadingAnchor),
            dictationWave.trailingAnchor.constraint(equalTo: suggestionBar.trailingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
        ])
        for index in 0..<3 {
            // A custom button: system buttons cross-fade every title change, which reads as lag in a
            // strip that updates on each key.
            // Кнопка типу custom: системні плавно змінюють кожен заголовок, і в смузі, що оновлюється
            // з кожною клавішею, це виглядає як затримка.
            let button = SuggestionKey(type: .custom)
            button.setTitleColor(Strip.text.withAlphaComponent(0.35), for: .highlighted)
            button.titleCenter = stripCenter
            button.setTitleColor(Strip.text, for: .normal)
            button.titleLabel?.font = Strip.font
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.6
            button.titleLabel?.lineBreakMode = .byClipping
            button.accessibilityIdentifier = "tacet-suggestion-\(index)"
            button.accessibilityHint = String(localized: "Replaces the word you are typing.")
            button.tag = index
            button.isEnabled = false
            button.isAccessibilityElement = false
            button.addTarget(self, action: #selector(suggestionTouched(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(suggestionTouchCancelled(_:)), for: [.touchUpOutside, .touchCancel])
            button.addAction(UIAction { [weak self] _ in self?.applySuggestion(at: index) }, for: .primaryActionTriggered)
            suggestionBar.addArrangedSubview(button)
            let divider = UIView()
            divider.isUserInteractionEnabled = false
            divider.isHidden = true
            divider.backgroundColor = Palette.caption.withAlphaComponent(0.22)
            divider.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(divider)
            let center = divider.centerYAnchor.constraint(equalTo: button.topAnchor, constant: PortraitMetrics.stripCenter)
            dividerCenters.append(center)
            NSLayoutConstraint.activate([
                divider.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                center,
                divider.heightAnchor.constraint(equalToConstant: 22),
                divider.widthAnchor.constraint(equalToConstant: 1),
            ])
            suggestionDividers.append(divider)
        }
        pinyinBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pinyinBar)
        NSLayoutConstraint.activate([
            pinyinBar.topAnchor.constraint(equalTo: suggestionBar.topAnchor),
            pinyinBar.bottomAnchor.constraint(equalTo: suggestionBar.bottomAnchor),
            pinyinBar.leadingAnchor.constraint(equalTo: suggestionBar.leadingAnchor),
            pinyinBar.trailingAnchor.constraint(equalTo: suggestionBar.trailingAnchor),
        ])
        pinyinBar.onTouch = { [weak self] in self?.keyFeedback() }
        pinyinBar.onChoice = { [weak self] choice in
            guard let self, choice.composition == pinyin.text else { return }
            commitPinyin(choice: choice.candidate)
        }
    }

    private func scheduleSuggestions() {
        guard canShowSuggestions else {
            cancelSuggestionRefresh()
            if suggestions != nil { displaySuggestions(nil) }
            return
        }
        suggestionGeneration &+= 1
        correctionRefresh?.cancel()
        correctionRefresh = nil
        guard suggestionRefresh == nil else { return }
        suggestionRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
                guard let self else { break }
                let generation = suggestionGeneration
                await refreshSuggestions(generation: generation)
                guard !Task.isCancelled else { return }
                if generation != suggestionGeneration { continue }
                suggestionRefresh = nil
                return
            }
        }
    }

    private func cancelSuggestionRefresh() {
        suggestionRefresh?.cancel()
        suggestionRefresh = nil
        correctionRefresh?.cancel()
        correctionRefresh = nil
    }

    private var canShowSuggestions: Bool {
        visible && page == .letters && !layout.usesPinyin && pending == nil && trackpad == nil
            && deleteRepeat == nil && layoutPicker == nil
    }

    private func prepareVocabulary() {
        let activeLayout = layout
        if activeLayout.usesPinyin {
            Task(priority: .utility) { [pinyinLexicon] in await pinyinLexicon.prepare() }
        } else {
            Task(priority: .utility) { [lexicon] in await lexicon.prepare(activeLayout) }
        }
        warmChecker()
    }

    private func suggestionContext(in proxy: UITextDocumentProxy) -> SuggestionContext? {
        guard proxy.autocorrectionType != .no, proxy.spellCheckingType != .no, proxy.isSecureTextEntry != true else {
            return nil
        }
        switch proxy.keyboardType {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad:
            return nil
        default:
            let field = Field(proxy)
            guard let word = KeyboardWord(before: field.before, after: field.after, selection: field.selection) else { return nil }
            return SuggestionContext(field: field, layout: layout, word: word)
        }
    }

    private func refreshSuggestions(generation: Int) async {
        guard canShowSuggestions, let context = suggestionContext(in: textDocumentProxy) else {
            displaySuggestions(nil)
            return
        }
        let match = await lexicon.match(for: context.word, layout: context.layout)
        guard !Task.isCancelled, generation == suggestionGeneration, canShowSuggestions,
              suggestionContext(in: textDocumentProxy) == context else { return }
        // Like the system keyboard, always offer the word at the caret, then refine the alternatives in place.
        // Як системна клавіатура, завжди показуємо слово біля курсора й уточнюємо варіанти на місці.
        let key = "\(context.layout.rawValue)|\(context.word.canComplete)|\(context.word.text)"
        let cached = checkerCache[key]
        displaySuggestions(suggestions(for: context, match: match, checker: cached))
        guard cached == nil, context.word.text.count >= 2, match.completions.count + match.corrections.count < 2 else { return }

        // UIKit's spelling checker is main-actor-only: call it only once typing pauses, and cache the answer.
        // Словник UIKit працює лише в головному потоці: звертаємося після паузи в наборі й кешуємо відповідь.
        correctionRefresh?.cancel()
        correctionRefresh = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                while self?.touchedKeys.isEmpty == false { try await Task.sleep(for: .milliseconds(50)) }
            } catch { return }
            guard let self, generation == suggestionGeneration, canShowSuggestions,
                  suggestionContext(in: textDocumentProxy) == context else { return }
            let result = checkerResult(for: context.word, layout: context.layout, known: match.known)
            if checkerCache.count >= 256 { checkerCache.removeAll() }
            checkerCache[key] = result
            displaySuggestions(suggestions(for: context, match: match, checker: result))
        }
    }

    private func suggestions(for context: SuggestionContext, match: KeyboardCompletionLexicon.Match,
                             checker: CheckerResult?) -> Suggestions {
        let system = checker?.words ?? []
        // Continuations of what is typed come first; our own typo fixes outrank the system's only
        // when the system also considers the word misspelled.
        // Спершу продовження набраного; власні виправлення одруківок випереджають системні лише
        // тоді, коли система теж вважає слово помилковим.
        let ordered = match.completions
            + (checker?.misspelled == true ? match.corrections + system : system + match.corrections)
        return Suggestions(context: context, choices: [context.word.text] + context.word.options(ordered).prefix(2))
    }

    private func checkerResult(for word: KeyboardWord, layout: KeyboardLayout, known: Bool) -> CheckerResult {
        guard let language = KeyboardWord.dictionary(for: layout, in: dictionaries) else {
            return CheckerResult(misspelled: false, words: [])
        }
        let range = NSRange(location: 0, length: word.text.utf16.count)
        let misspelled = !known && checker.rangeOfMisspelledWord(in: word.text, range: range, startingAt: 0,
                                                                 wrap: false, language: language) == range
        let completions = word.completions(checker.completions(forPartialWordRange: range, in: word.text,
                                                               language: language) ?? [])
        // Some dictionaries (Ukrainian) never flag a word but still return guesses, so an unknown
        // word with no continuation is treated as a possible typo too.
        // Деякі словники (український) ніколи не позначають слово помилковим, але повертають
        // варіанти, тож невідоме слово без продовжень теж вважаємо можливою помилкою.
        guard misspelled || (!known && completions.isEmpty) else { return CheckerResult(misspelled: false, words: completions) }
        let corrections = word.corrections(checker.guesses(forWordRange: range, in: word.text, language: language) ?? [])
        // An unfinished word at the caret is most likely still being typed; elsewhere it is a typo.
        // Незавершене слово біля курсора, найімовірніше, ще набирається; деінде це помилка.
        return CheckerResult(misspelled: misspelled || !corrections.isEmpty,
                             words: word.canComplete ? completions + corrections : corrections + completions)
    }

    /// The first checker call per language loads its dictionary on the main thread (37–152 ms measured
    /// on an iPhone 15 Pro). Pay that while the keyboard is idle instead of in the first typing pause.
    /// Перший виклик словника для мови завантажує його в головному потоці (37–152 мс на iPhone 15 Pro).
    /// Робимо це, поки клавіатура простоює, а не під час першої паузи в наборі.
    private func warmChecker() {
        let target = layout
        guard !target.usesPinyin, !warmedLayouts.contains(target) else { return }
        checkerWarmup?.cancel()
        checkerWarmup = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                while let self, !touchedKeys.isEmpty || .now - lastEdit < .milliseconds(400) {
                    try await Task.sleep(for: .milliseconds(120))
                }
            } catch { return }
            guard let self, visible, layout == target, let sample = target.keys.first?.first?.text,
                  let language = KeyboardWord.dictionary(for: target, in: dictionaries) else { return }
            let text = sample + sample
            let range = NSRange(location: 0, length: text.utf16.count)
            _ = checker.rangeOfMisspelledWord(in: text, range: range, startingAt: 0, wrap: false, language: language)
            _ = checker.completions(forPartialWordRange: range, in: text, language: language)
            warmedLayouts.insert(target)
        }
    }

    private func displaySuggestions(_ options: Suggestions?) {
        guard suggestions != options else { return }
        suggestions = options
        let choices = options?.choices ?? []
        let locale = options.map { Locale(identifier: $0.context.layout.speechLocale) }
        let open = locale?.quotationBeginDelimiter ?? "“"
        let close = locale?.quotationEndDelimiter ?? "”"
        for (index, view) in suggestionBar.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            let title = choices.indices.contains(index) ? choices[index] : nil
            let label = index == 0 ? title.map { open + $0 + close } : title
            if button.title(for: .normal) != label {
                button.setTitle(label, for: .normal)
            }
            if button.isEnabled != (title != nil) {
                button.isEnabled = title != nil
                button.isAccessibilityElement = title != nil
            }
            suggestionDividers[index].isHidden = index >= choices.count - 1
        }
        updateSuggestionVisibility()
    }

    private func updateSuggestionVisibility() {
        let hidden = !canShowSuggestions || !statusLabel.isHidden || suggestions == nil
        if suggestionBar.isHidden != hidden { suggestionBar.isHidden = hidden }
        let pinyinHidden = !visible || !layout.usesPinyin || page != .letters || pinyin.text.isEmpty
            || !statusLabel.isHidden || pending != nil || trackpad != nil || layoutPicker != nil
        if pinyinBar.isHidden != pinyinHidden { pinyinBar.isHidden = pinyinHidden }
        if micDivider.isHidden != hidden { micDivider.isHidden = hidden }
        if dictationButton.isHidden != (layoutPicker != nil) { dictationButton.isHidden = layoutPicker != nil }
        let recording = pending?.state == .recording
        let waveHidden = !visible || layoutPicker != nil || !statusLabel.isHidden
            || !(recording || pending?.state == .finishing)
        if dictationWave.isHidden != waveHidden { dictationWave.isHidden = waveHidden }
        dictationWave.isActive = recording && !waveHidden
    }

    @objc private func suggestionTouched(_ button: UIButton) {
        pressedSuggestion = suggestions.map { (button.tag, $0) }
        keyFeedback()
    }

    @objc private func suggestionTouchCancelled(_ button: UIButton) {
        if pressedSuggestion?.index == button.tag { pressedSuggestion = nil }
    }

    private func applySuggestion(at index: Int) {
        let proxy = textDocumentProxy
        let captured = pressedSuggestion
        pressedSuggestion = nil
        guard canShowSuggestions, statusLabel.isHidden, index == (captured?.index ?? index),
              let suggestions = captured?.options ?? suggestions,
              suggestions.choices.indices.contains(index), suggestionContext(in: proxy) == suggestions.context
        else {
            scheduleSuggestions()
            return
        }
        let word = suggestions.context.word
        if index == 0 {
            if word.addsSpace { edit { $0.insertText(" ") } }
            displaySuggestions(nil)
            return
        }
        let choice = suggestions.choices[index]
        if word.canComplete, choice.hasPrefix(word.text) {
            let suffix = String(word.replacement(choice).dropFirst(word.text.count))
            edit { $0.insertText(suffix) }
            displaySuggestions(nil)
            return
        }
        let replacement = word.replacement(choice)
        edit { proxy in
            if word.selected {
                proxy.insertText(replacement)
                return
            }
            if !word.trailing.isEmpty {
                proxy.adjustTextPosition(byCharacterOffset: word.trailing.utf16.count)
                guard proxy.documentIdentifier == suggestions.context.field.document,
                      let moved = suggestionContext(in: proxy)?.word, moved.text == word.text, moved.trailing.isEmpty,
                      !moved.selected else { return }
            }
            for _ in word.text { proxy.deleteBackward() }
            proxy.insertText(replacement)
        }
        displaySuggestions(nil)
    }

    private func buildKeys() {
        touchedKeys.removeAll()
        heldLetters.removeAll()
        committedEarly.removeAll()
        latestTouch = nil
        letterButtons.removeAll()
        shiftButton = nil
        while let row = keys.arrangedSubviews.first { row.removeFromSuperview() }
        let rows: [[KeyboardLayout.Key]]
        switch page {
        case .letters: rows = layout.keys
        case .numbers: rows = ["1234567890", "-/:;()₴&@“", ".,?!'"].map { $0.map { .init(String($0)) } }
        case .extended: rows = ["[]{}#%^*+=", "_\\|~<>€£¥•", "…!?“”"].map { $0.map { .init(String($0)) } }
        }
        let letters = page == .letters
        for (index, characters) in rows.enumerated() {
            let row = UIStackView()
            row.distribution = .fillEqually
            row.spacing = 6
            var leadingControl: UIButton?
            var delete: UIButton?
            var firstLetter: UIButton?
            if letters && (layout == .english || layout.usesPinyin) && index == 1 {
                row.isLayoutMarginsRelativeArrangement = true
                row.directionalLayoutMargins = .init(top: 0, leading: 19, bottom: 0, trailing: 19)
            }
            if index == 2 {
                let button: UIButton
                if letters {
                    button = key("", symbol: uppercase ? "shift.fill" : "shift",
                                 accessibility: String(localized: "Shift"), isModifier: true) { [weak self] in
                        guard let self else { return }
                        manualShift = true
                        setUppercase(!uppercase)
                    }
                    shiftButton = button
                } else {
                    button = key(page == .numbers ? "#+=" : "123", isModifier: true) { [weak self] in
                        guard let self else { return }
                        page = page == .numbers ? .extended : .numbers
                        buildKeys()
                    }
                }
                leadingControl = button
                row.addArrangedSubview(button)
            }
            for letter in characters {
                let title = KeyboardLayout.Key.title(for: letter.output(shift: uppercase && letters))
                let button = key(title, showsPreview: true) { [weak self] in
                    guard let self else { return }
                    insertLetter(letter.output(shift: uppercase && letters))
                }
                if letters { letterButtons.append((button, letter)) }
                let variants = letter.text.first.map { letters ? layout.alternatives(for: $0) : punctuationAlternatives(for: $0) } ?? ""
                if !variants.isEmpty {
                    button.menu = UIMenu(children: [
                        UIDeferredMenuElement.uncached { [weak self] complete in
                            let capitals = letters && self?.uppercase == true
                            complete(variants.map { variant in
                                let text = capitals ? variant.uppercased() : String(variant)
                                return UIAction(title: text) { [weak self] _ in self?.insertLetter(text) }
                            })
                        },
                    ])
                }
                if firstLetter == nil { firstLetter = button }
                row.addArrangedSubview(button)
            }
            if index == 2 {
                // Like the system keyboard, delete on touch-down; touch-up only covers activations
                // that never sent touch-down (VoiceOver).
                // Як системна клавіатура, видаляємо при дотику; відпускання лише підстраховує
                // активації без дотику (VoiceOver).
                let button = key("", symbol: "delete.left", accessibility: String(localized: "Delete"),
                                 isModifier: true) { [weak self] in
                    guard let self else { return }
                    if deletedOnTouchDown { deletedOnTouchDown = false } else { deleteLetter() }
                }
                button.addAction(UIAction { [weak self] _ in
                    guard let self, trackpad == nil else { return }
                    deletedOnTouchDown = true
                    deleteLetter()
                }, for: .touchDown)
                button.addAction(UIAction { [weak self] _ in self?.deletedOnTouchDown = false },
                                 for: [.touchUpOutside, .touchCancel])
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:)))
                hold.minimumPressDuration = KeyboardDeletion.holdSeconds
                button.addGestureRecognizer(hold)
                delete = button
                row.addArrangedSubview(button)
            }
            if index == 2, (!letters || layout == .english || layout.usesPinyin), let firstLetter, let leadingControl, let delete {
                row.distribution = .fill
                NSLayoutConstraint.activate(row.arrangedSubviews.filter { $0 !== firstLetter }.map { view in
                    view.widthAnchor.constraint(equalTo: firstLetter.widthAnchor,
                                                multiplier: view === leadingControl || view === delete ? 1.5 : 1)
                })
            }
            keys.addArrangedSubview(row)
        }
        let bottom = UIStackView()
        bottom.spacing = 6
        bottom.addArrangedSubview(globe)
        let alphabet = layout.isCyrillic ? "АБВ" : layout == .hindi ? "अआ" : layout.usesPinyin ? "拼音" : "ABC"
        let numbers = key(letters ? "123" : alphabet,
                          isModifier: true) { [weak self] in
            guard let self else { return }
            commitPinyin()
            page = letters ? .numbers : .letters
            manualShift = false
            uppercase = false
            refreshAutomaticCase()
            buildKeys()
        }
        bottom.addArrangedSubview(numbers)
        let language = key(layout.code, accessibility: String(localized: "Keyboard language"), isModifier: true) { [weak self] in
            guard let self, let current = enabledLayouts.firstIndex(of: layout) else { return }
            setLanguage(enabledLayouts[(current + 1) % enabledLayouts.count])
        }
        language.accessibilityValue = layout.name
        language.isEnabled = enabledLayouts.count > 1
        language.accessibilityHint = String(localized: "Hold to see all enabled keyboard languages.")
        language.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Keyboard languages")) { [weak self] _ in
                self?.showLayoutPicker() ?? false
            },
        ]
        let layoutHold = UILongPressGestureRecognizer(target: self, action: #selector(holdLanguage(_:)))
        layoutHold.minimumPressDuration = 0.38
        language.addGestureRecognizer(layoutHold)
        bottom.addArrangedSubview(language)
        let space = key(layout.space, accessibility: String(localized: "Space"), isModifier: true) { [weak self] in
            self?.insertBoundary(" ")
        }
        let trackpadHold = UILongPressGestureRecognizer(target: self, action: #selector(holdSpace(_:)))
        trackpadHold.minimumPressDuration = 0.38
        space.addGestureRecognizer(trackpadHold)
        space.accessibilityHint = String(localized: "Hold and drag to move the cursor.")
        space.configuration?.baseBackgroundColor = Palette.key
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(space)
        let returnKey = key("", symbol: "return", accessibility: String(localized: "Return"),
                            isModifier: true) { [weak self] in
            self?.insertBoundary("\n")
        }
        bottom.addArrangedSubview(returnKey)
        NSLayoutConstraint.activate([
            numbers.widthAnchor.constraint(equalToConstant: 42),
            language.widthAnchor.constraint(equalToConstant: 42),
            returnKey.widthAnchor.constraint(equalToConstant: 90)
        ])
        keys.addArrangedSubview(bottom)
        view.bringSubviewToFront(statusLabel)
        view.bringSubviewToFront(keyPreview)
        scheduleSuggestions()
    }

    private func refreshLayouts() {
        if let saved = try? DictationBridge.keyboardLayouts() {
            enabledLayouts = KeyboardLayout.ordered(saved)
        }
        if !enabledLayouts.contains(layout) { layout = enabledLayouts[0] }
    }

    @objc private func holdLanguage(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { _ = showLayoutPicker() }
    }

    private func showLayoutPicker() -> Bool {
        guard layoutPicker == nil, trackpad == nil, pending == nil else { return false }
        commitPinyin()
        touchedKeys.removeAll()
        heldLetters.removeAll()
        committedEarly.removeAll()
        clearPreview()
        cancelSuggestionRefresh()
        displaySuggestions(nil)

        let title = UILabel()
        title.text = String(localized: "Keyboard languages")
        title.textColor = .label
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textAlignment = .center
        title.accessibilityTraits.insert(.header)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = String(localized: "Close")
        close.addAction(UIAction { [weak self] _ in self?.closeLayoutPicker() }, for: .primaryActionTriggered)
        let header = UIStackView(arrangedSubviews: [title, close])
        close.widthAnchor.constraint(equalToConstant: 36).isActive = true
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 6
        grid.distribution = .fillEqually
        let columns = min(3, enabledLayouts.count)
        for start in stride(from: 0, to: enabledLayouts.count, by: columns) {
            let row = UIStackView()
            row.spacing = 6
            row.distribution = .fillEqually
            for choice in enabledLayouts.dropFirst(start).prefix(columns) {
                var config = UIButton.Configuration.filled()
                config.title = choice.name
                config.baseBackgroundColor = choice == layout ? Palette.accent : Palette.key
                config.baseForegroundColor = choice == layout ? .white : .label
                config.contentInsets = .init(top: 4, leading: 5, bottom: 4, trailing: 5)
                let button = UIButton(configuration: config)
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                if choice == layout { button.accessibilityTraits.insert(.selected) }
                button.addAction(UIAction { [weak self] _ in
                    self?.keyFeedback()
                    self?.closeLayoutPicker()
                    self?.setLanguage(choice)
                }, for: .primaryActionTriggered)
                row.addArrangedSubview(button)
            }
            while row.arrangedSubviews.count < columns { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
        }
        let picker = UIStackView(arrangedSubviews: [header, grid])
        picker.axis = .vertical
        picker.spacing = 6
        picker.accessibilityViewIsModal = true
        picker.translatesAutoresizingMaskIntoConstraints = false
        layoutPicker = picker
        keys.isHidden = true
        statusLabel.isHidden = true
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            picker.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        keyFeedback()
        UIAccessibility.post(notification: .screenChanged, argument: title)
        return true
    }

    private func closeLayoutPicker() {
        guard let layoutPicker else { return }
        layoutPicker.removeFromSuperview()
        self.layoutPicker = nil
        keys.isHidden = false
        renderState()
        scheduleSuggestions()
    }

    private func setLanguage(_ selected: KeyboardLayout) {
        commitPinyin()
        clearPreview()
        displaySuggestions(nil)
        layout = selected
        prepareVocabulary()
        UserDefaults.standard.set(selected.rawValue, forKey: "tacet.keyboardLayout")
        page = .letters
        manualShift = false
        refreshAutomaticCase()
        buildKeys()
    }

    private func appendPinyin(_ input: String) -> Bool {
        guard layout.usesPinyin, page == .letters, let letter = KeyboardPinyinComposition.letter(input) else { return false }
        let proxy = textDocumentProxy
        guard proxy.isSecureTextEntry != true, proxy.keyboardType != .asciiCapable else { return false }
        switch proxy.keyboardType {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad: return false
        default: break
        }
        clearPinyinIfFieldChanged()
        if pinyin.text.count >= KeyboardPinyinComposition.maximumLength { commitPinyin() }
        if pinyinField == nil { pinyinField = Field(proxy) }
        Self.wakeRequest = nil
        cancelPending()
        lastEdit = .now
        if errorUntil > Date() {
            errorUntil = .distantPast
            renderState()
        }
        pinyin.append(letter)
        refreshPinyin()
        return true
    }

    private func refreshPinyin() {
        pinyinRefresh?.cancel()
        pinyinCandidates = []
        let text = pinyin.text
        let field = pinyinField
        pinyinBar.display(text, candidates: [])
        updateSuggestionVisibility()
        pinyinRefresh = Task { [weak self] in
            guard let lexicon = self?.pinyinLexicon else { return }
            let candidates = await lexicon.candidates(for: text)
            guard let self, !Task.isCancelled, pinyin.text == text, pinyinField == field else { return }
            clearPinyinIfFieldChanged()
            guard pinyin.text == text else { return }
            pinyinCandidates = candidates
            pinyinBar.display(text, candidates: candidates)
            pinyinRefresh = nil
        }
    }

    private func clearPinyinIfFieldChanged() {
        if let pinyinField, pinyinField != Field(textDocumentProxy) { clearPinyin() }
    }

    private func clearPinyin() {
        guard pinyinField != nil else { return }
        pinyinRefresh?.cancel()
        pinyinRefresh = nil
        pinyin = KeyboardPinyinComposition()
        pinyinField = nil
        pinyinCandidates = []
        pinyinBar.display("", candidates: [])
        updateSuggestionVisibility()
    }

    @discardableResult
    private func commitPinyin(choice: String? = nil, suffix: String = "") -> Bool {
        guard let field = pinyinField, !pinyin.text.isEmpty else { return false }
        guard choice.map(pinyinCandidates.contains) != false else { return false }
        let output = (choice ?? pinyin.text) + suffix
        clearPinyin()
        guard field == Field(textDocumentProxy) else { return false }
        edit { $0.insertText(output) }
        return true
    }

    private func deletePinyinLetter() -> Bool {
        clearPinyinIfFieldChanged()
        guard !pinyin.text.isEmpty else { return false }
        pinyin.deleteBackward()
        if pinyin.text.isEmpty { clearPinyin() }
        else { refreshPinyin() }
        return true
    }

    private func insertLetter(_ text: String) {
        if !appendPinyin(text) { edit { $0.insertText(text) } }
        guard page == .letters else { return }
        manualShift = false
        setUppercase(capitalization == .allCharacters)
    }

    private func insertBoundary(_ text: String) {
        if commitPinyin(choice: pinyinCandidates.first,
                        suffix: text == " " && !pinyinCandidates.isEmpty ? "" : text) { return }
        let before = page == .letters && capitalization == .sentences
            ? textDocumentProxy.documentContextBeforeInput ?? "" : ""
        edit { $0.insertText(text) }
        guard page == .letters else { return }
        manualShift = false
        setUppercase(capitalization.startsUppercase(after: before + text))
    }

    private func deleteLetter() {
        if deletePinyinLetter() { return }
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput ?? ""
        let hadSelection = proxy.selectedText?.isEmpty == false
        edit { $0.deleteBackward() }
        guard page == .letters else { return }
        manualShift = false
        setUppercase(capitalization.startsUppercase(after: hadSelection ? before : String(before.dropLast())))
    }

    private func refreshCaseAfterExternalChange() {
        guard touchedKeys.isEmpty, .now - lastEdit >= .milliseconds(160) else { return }
        refreshAutomaticCase()
    }

    private func refreshAutomaticCase() {
        guard visible, page == .letters, !manualShift else { return }
        guard layout.supportsAutomaticCapitalization else {
            capitalization = .none
            setUppercase(false)
            return
        }
        let proxy = textDocumentProxy
        switch proxy.autocapitalizationType ?? .sentences {
        case .none: capitalization = .none
        case .sentences: capitalization = .sentences
        case .words: capitalization = .words
        case .allCharacters: capitalization = .allCharacters
        @unknown default: capitalization = .none
        }
        setUppercase(capitalization.startsUppercase(after: proxy.documentContextBeforeInput ?? ""))
    }

    private func setUppercase(_ value: Bool) {
        guard uppercase != value else { return }
        uppercase = value
        guard !caseRenderPending else { return }
        caseRenderPending = true
        DispatchQueue.main.async { [weak self] in self?.renderLetterCase() }
    }

    private func renderLetterCase() {
        caseRenderPending = false
        shiftButton?.configuration?.image = UIImage(systemName: uppercase ? "shift.fill" : "shift",
                                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        for (button, letter) in letterButtons {
            let title = KeyboardLayout.Key.title(for: letter.output(shift: uppercase))
            if button.title(for: .normal) != title { button.setTitle(title, for: .normal) }
            button.accessibilityLabel = title
        }
    }

    @objc private func showKeyPreview(_ button: UIButton) {
        guard latestTouch === button, let title = button.title(for: .normal) else { return }
        showKeyPreview(button, title: title)
    }

    private func showKeyPreview(_ button: UIButton, title: String) {
        guard trackpad == nil else { return }
        previewDismissal?.cancel()
        previewButton = button
        previewStarted = .now
        keyPreview.frame = KeyboardPreview.frame(
            above: button.convert(button.bounds.insetBy(dx: 0, dy: rowPadding), to: view), inside: view.bounds
        )
        keyPreview.text = title
        keyPreview.isHidden = false
    }

    @objc private func endKeyPreview(_ button: UIButton) {
        guard previewButton === button else { return }
        previewDismissal?.cancel()
        let earliest = previewStarted + .milliseconds(120)
        previewDismissal = Task { [weak self] in
            do { try await Task.sleep(until: earliest, clock: .continuous) } catch { return }
            self?.clearPreview()
        }
    }

    private func clearPreview() {
        previewDismissal?.cancel()
        previewDismissal = nil
        previewButton = nil
        keyPreview.isHidden = true
    }

    @objc private func keyFeedback() {
        impact(intensity: 0.7)
    }

    private func impact(intensity: CGFloat) {
        feedback?.impactOccurred(intensity: intensity)
    }

    @objc private func keyTouched(_ button: UIButton) {
        guard trackpad == nil else { return }
        // Like the system keyboard, a letter still held when the next key goes down is typed first,
        // so fast overlapping taps keep their order.
        // Як у системній клавіатурі, літера, яку ще тримають у момент дотику до наступної клавіші,
        // вводиться першою, тож швидкі дотики «внахлест» зберігають порядок.
        for held in heldLetters where held !== button {
            held.sendActions(for: .primaryActionTriggered)
            committedEarly.insert(ObjectIdentifier(held))
        }
        heldLetters.removeAll()
        if button is TypingKey { heldLetters.append(button) }
        verticalCursorMove?.cancel()
        touchedKeys.insert(ObjectIdentifier(button))
        latestTouch = button
        if button is TypingKey { showKeyPreview(button) }
        else { clearPreview() }
        keyFeedback()
    }

    @objc private func keyTouchCancelled(_ button: UIButton) {
        touchedKeys.remove(ObjectIdentifier(button))
        heldLetters.removeAll { $0 === button }
        committedEarly.remove(ObjectIdentifier(button))
        scheduleSuggestions()
    }

    @objc private func holdDelete(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard trackpad == nil else { return }
            clearPinyinIfFieldChanged()
            if !pinyin.text.isEmpty {
                deleteRepeat?.cancel()
                deleteRepeat = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, deletePinyinLetter() else { self?.endDeleteRepeat(); return }
                        impact(intensity: 0.45)
                        do { try await Task.sleep(for: KeyboardDeletion.interval(for: .character)) } catch { return }
                    }
                }
                return
            }
            let start = ContinuousClock.now
            let document = textDocumentProxy.documentIdentifier
            deleteRepeat?.cancel()
            cancelSuggestionRefresh()
            displaySuggestions(nil)
            deleteRepeat = Task { [weak self] in
                var crossedEmptyContext = false
                while !Task.isCancelled {
                    guard let self, visible, textDocumentProxy.documentIdentifier == document else {
                        self?.endDeleteRepeat()
                        return
                    }
                    let unit = KeyboardDeletion.unit(after: .now - start + .seconds(KeyboardDeletion.holdSeconds))
                    let proxy = textDocumentProxy
                    let selected = proxy.selectedText?.isEmpty == false
                    let count = selected ? 1 : KeyboardDeletion.count(in: proxy.documentContextBeforeInput ?? "", unit: unit)
                    guard count > 0 || !crossedEmptyContext else {
                        endDeleteRepeat()
                        return
                    }
                    crossedEmptyContext = count == 0
                    edit { proxy in
                        for _ in 0..<max(1, count) { proxy.deleteBackward() }
                    }
                    // A lighter tick for repeats, so a long hold does not buzz.
                    // Легший імпульс для повторів, щоб довге утримання не «гуділо».
                    if count > 0 { impact(intensity: 0.45) }
                    do { try await Task.sleep(for: KeyboardDeletion.interval(for: unit)) } catch { return }
                }
            }
        case .changed:
            if let key = gesture.view, !key.bounds.insetBy(dx: -8, dy: -8).contains(gesture.location(in: key)) {
                endDeleteRepeat()
            }
        case .ended, .cancelled, .failed:
            endDeleteRepeat()
        default:
            break
        }
    }

    private func endDeleteRepeat() {
        guard let task = deleteRepeat else { return }
        deleteRepeat = nil
        task.cancel()
        manualShift = false
        refreshAutomaticCase()
        scheduleSuggestions()
    }

    @objc private func holdSpace(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            commitPinyin()
            endDeleteRepeat()
            cancelPending()
            Self.wakeRequest = nil
            trackpad = Trackpad(document: textDocumentProxy.documentIdentifier, anchor: point)
            keys.alpha = 0.35
            clearPreview()
            cancelSuggestionRefresh()
            displaySuggestions(nil)
            keyFeedback()
            renderState()
        case .changed:
            moveCursor(to: point)
        case .ended, .cancelled, .failed:
            endTrackpad()
        default:
            break
        }
    }

    private func moveCursor(to point: CGPoint) {
        guard var trackpad, verticalCursorMove == nil else { return }
        let proxy = textDocumentProxy
        guard proxy.documentIdentifier == trackpad.document else {
            endTrackpad()
            return
        }
        let dx = point.x - trackpad.anchor.x
        let dy = point.y - trackpad.anchor.y
        if abs(dy) >= 20, abs(dy) > abs(dx) {
            trackpad.anchor = point
            self.trackpad = trackpad
            moveCursorVertically(in: proxy, down: dy > 0)
        } else {
            let steps = max(-12, min(12, Int(dx / 7)))
            guard steps != 0 else { return }
            let offset = KeyboardCursor.horizontalOffset(before: proxy.documentContextBeforeInput,
                                                         after: proxy.documentContextAfterInput, steps: steps)
            trackpad.anchor.x += CGFloat(steps) * 7
            trackpad.anchor.y = point.y
            self.trackpad = trackpad
            proxy.adjustTextPosition(byCharacterOffset: offset == 0 ? steps.signum() : offset)
        }
    }

    private func moveCursorVertically(in proxy: UITextDocumentProxy, down: Bool) {
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        let offset = KeyboardCursor.verticalOffset(before: before, after: after, down: down)
        if offset != 0 {
            proxy.adjustTextPosition(byCharacterOffset: offset)
            return
        }

        // Wait for the host to publish the new paragraph after moving the cursor.
        // Чекаємо, доки поле надасть новий абзац після руху курсора.
        let direction = down ? 1 : -1
        let distance = down ? after.utf16.count : before.utf16.count
        let column = KeyboardCursor.column(before: before)
        let document = proxy.documentIdentifier
        proxy.adjustTextPosition(byCharacterOffset: direction * (distance + 1))
        verticalCursorMove = Task { [weak self] in
            defer { self?.verticalCursorMove = nil }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self, visible, textDocumentProxy.documentIdentifier == document,
                  textDocumentProxy.selectedText?.isEmpty != false else { return }
            let adjacentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let adjacentAfter = textDocumentProxy.documentContextAfterInput ?? ""
            let offset = KeyboardCursor.offset(toColumn: column, before: adjacentBefore, after: adjacentAfter)
            if offset != 0 { textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
        }
    }

    private func endTrackpad() {
        guard trackpad != nil else { return }
        trackpad = nil
        keys.alpha = 1
        manualShift = false
        refreshAutomaticCase()
        renderState()
        scheduleSuggestions()
    }

    private func punctuationAlternatives(for character: Character) -> String {
        guard layout == .spanish else { return "" }
        if character == "?" { return "¿" }
        if character == "!" { return "¡" }
        return ""
    }

    private var keyBackgroundInsets: NSDirectionalEdgeInsets {
        .init(top: rowPadding, leading: 0, bottom: rowPadding, trailing: 0)
    }

    private func key(_ title: String, symbol: String? = nil, accessibility: String? = nil,
                     isModifier: Bool = false, showsPreview: Bool = false, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 7
        configuration.background.backgroundInsets = keyBackgroundInsets
        if let symbol {
            configuration.image = UIImage(systemName: symbol,
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        } else {
            configuration.title = title
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: isModifier ? 16 : 23, weight: .regular)
            return attributes
        }
        configuration.baseBackgroundColor = isModifier ? Palette.modifier : Palette.key
        configuration.baseForegroundColor = .label
        configuration.contentInsets = isModifier ? .init(top: 0, leading: 4, bottom: 0, trailing: 4) : .zero
        let button: UIButton = showsPreview ? TypingKey(title: title, color: Palette.key, inset: rowPadding)
            : UIButton(configuration: configuration)
        button.isExclusiveTouch = false
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            touchedKeys.remove(ObjectIdentifier(button))
            heldLetters.removeAll { $0 === button }
            if committedEarly.remove(ObjectIdentifier(button)) != nil { return }
            guard trackpad == nil else { return }
            let previewTitle = showsPreview && latestTouch === button ? button.title(for: .normal) : nil
            action()
            if let previewTitle, latestTouch === button, button.window != nil {
                if previewButton !== button || keyPreview.isHidden { showKeyPreview(button, title: previewTitle) }
                endKeyPreview(button)
            }
            if !showsPreview { scheduleSuggestions() }
        }, for: .primaryActionTriggered)
        button.addTarget(self, action: #selector(keyTouched(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(keyTouchCancelled(_:)), for: [.touchUpOutside, .touchCancel])
        if showsPreview {
            button.addTarget(self, action: #selector(showKeyPreview(_:)), for: .touchDragEnter)
            button.addTarget(self, action: #selector(endKeyPreview(_:)),
                             for: [.touchUpOutside, .touchDragExit, .touchCancel])
        }
        button.accessibilityLabel = accessibility ?? title
        return button
    }

    private func edit(_ action: (UITextDocumentProxy) -> Void) {
        Self.wakeRequest = nil
        cancelPending()
        lastEdit = .now
        action(textDocumentProxy)
        scheduleSuggestions()
    }

    @objc private func dictationTapped() {
        guard trackpad == nil else { return }
        commitPinyin()
        latestTouch = nil
        clearPreview()
        verticalCursorMove?.cancel()
        guard hasFullAccess else {
            showError(String(localized: "Allow Full Access in Settings for dictation."))
            return
        }
        do {
            if pending == nil {
                status = try DictationBridge.status().flatMap { $0.expires > Date() ? $0 : nil }
            }
            if var request = pending, request.state == .recording {
                try DictationBridge.send(.init(session: request.session, request: request.id, action: .stop))
                request.state = .finishing
                request.expires = Date().addingTimeInterval(DictationBridge.processingTimeout(for: request.field.selection))
                pending = request
            } else if pending == nil, let status, status.phase == .ready, status.expires > Date() {
                Self.wakeRequest = nil
                try beginDictation(status, layout: layout)
            } else if pending == nil, status == nil {
                try openTacet()
            } else if pending == nil {
                showError(String(localized: "The previous dictation is finishing."))
            }
            renderState()
        } catch {
            cancelPending()
            showError(error.localizedDescription)
        }
    }

    private func beginDictation(_ status: DictationBridge.Status, layout: KeyboardLayout) throws {
        let request = Request(session: status.session, id: UUID(), field: Field(textDocumentProxy))
        let selection = request.field.selection
        if let selection, selection.utf8.count > SelectionEditLimits.maximumInputBytes {
            throw DictationBridge.BridgeError.selectionTooLong
        }
        try DictationBridge.send(.init(session: request.session, request: request.id, action: .start,
                                      layout: layout, selection: selection))
        pending = request
        displaySuggestions(nil)
        errorMessage = nil
    }

    private func openTacet() throws {
        if let wake = Self.wakeRequest, wake.expires > Date() { return }
        let url = try DictationBridge.wakeURL()
        Self.wakeRequest = WakeRequest(field: Field(textDocumentProxy), layout: layout,
                                      expires: Date().addingTimeInterval(DictationBridge.wakeTimeout))
        // Resolve the application via UIKit's responder chain for the containing app.
        // Отримуємо застосунок-власник через ланцюжок відповідачів UIKit.
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url) { [weak self] opened in
                    if !opened {
                        Self.wakeRequest = nil
                        self?.showError(String(localized: "Open Tacet or use the Action Button to start dictation."))
                    }
                }
                return
            }
            responder = current.next
        }
        Self.wakeRequest = nil
        showError(String(localized: "Open Tacet or use the Action Button to start dictation."))
    }

    private func poll() async {
        guard visible else { return }
        // Not every host reports a caret move (a tap on a word) to the keyboard, so also notice here
        // that the word at the caret is no longer the one the strip shows.
        // Не кожен застосунок повідомляє клавіатурі про рух курсора (дотик до слова), тож і тут
        // помічаємо, що слово біля курсора вже не те, яке показує смуга.
        if canShowSuggestions, touchedKeys.isEmpty, .now - lastEdit >= .milliseconds(280),
           suggestionContext(in: textDocumentProxy) != suggestions?.context {
            scheduleSuggestions()
        }
        if pending == nil, Self.wakeRequest == nil,
           (!touchedKeys.isEmpty || trackpad != nil || deleteRepeat != nil || .now - lastEdit < .milliseconds(280)) {
            return
        }
        guard hasFullAccess else {
            if pending != nil { cancelPending() }
            status = nil
            renderState()
            return
        }
        do {
            let updated = try await Task.detached(priority: .utility) { try DictationBridge.status() }.value
            guard visible, !Task.isCancelled else { return }
            status = updated.flatMap { $0.expires > Date() ? $0 : nil }
            if let wake = Self.wakeRequest {
                if wake.expires <= Date() {
                    Self.wakeRequest = nil
                } else if pending == nil, let status, status.phase == .ready,
                          wake.field == Field(textDocumentProxy) {
                    Self.wakeRequest = nil
                    try beginDictation(status, layout: wake.layout)
                }
            }
            if let request = pending {
                if request.field != Field(textDocumentProxy) {
                    cancelPending()
                    showError(String(localized: "The text field changed. Dictate again here."))
                } else if request.expires < Date() || status?.session != request.session {
                    cancelPending()
                    showError(String(localized: "The session ended. Start a new session to dictate."))
                } else if let status, status.request == request.id {
                    handle(status, request: request)
                }
            }
        } catch {
            guard visible, !Task.isCancelled else { return }
            let requestedDictation = pending != nil || Self.wakeRequest != nil
            cancelPending()
            status = nil
            if requestedDictation {
                Self.wakeRequest = nil
                showError(error.localizedDescription)
            }
        }
        renderState()
    }

    private func handle(_ status: DictationBridge.Status, request: Request) {
        switch status.phase {
        case .recording:
            if request.state == .starting {
                pending?.state = .recording
                pending?.expires = Date().addingTimeInterval(90)
            }
        case .processing:
            if request.state != .finishing {
                pending?.state = .finishing
                pending?.expires = Date().addingTimeInterval(DictationBridge.processingTimeout(for: request.field.selection))
            }
        case .result, .error:
            pending = nil
            try? DictationBridge.send(.init(session: request.session, request: request.id, action: .consume))
            if status.phase == .result, let text = status.text,
               !text.isEmpty || request.field.selection?.isEmpty == false {
                if text.isEmpty { textDocumentProxy.deleteBackward() }
                else { textDocumentProxy.insertText(text) }
                manualShift = false
                refreshAutomaticCase()
                scheduleSuggestions()
                if let warning = status.warning { showError(warning) }
            } else {
                showError(status.text ?? String(localized: "Dictation failed. Try again."))
            }
        case .ready:
            break
        }
    }

    private func cancelPending() {
        if let request = pending {
            pending = nil
            try? DictationBridge.send(.init(session: request.session, request: request.id, action: .cancel))
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorUntil = Date().addingTimeInterval(6)
        UIAccessibility.post(notification: .announcement, argument: message)
        renderState()
    }

    private func renderState() {
        let state = DictationButtonState(request: pending?.state, hasSession: status != nil,
                                         local: status?.local == true)
        if renderedDictation != state {
            renderedDictation = state
            renderDictationButton(state)
        }
        let message = trackpad != nil
            ? String(localized: "Trackpad · Drag to move the cursor")
            : (errorUntil > Date() ? errorMessage : nil)
        if statusLabel.text != message { statusLabel.text = message }
        let hideStatus = message == nil || layoutPicker != nil
        if statusLabel.isHidden != hideStatus { statusLabel.isHidden = hideStatus }
        updateSuggestionVisibility()
    }

    private func renderDictationButton(_ state: DictationButtonState) {
        let title: String
        let symbol: String
        var waiting = false
        switch state.request {
        case .starting:
            title = String(localized: "Starting…")
            symbol = "mic"
            dictationButton.isEnabled = false
            waiting = true
        case .recording:
            title = String(localized: "Stop dictation")
            symbol = "stop.fill"
            dictationButton.isEnabled = true
        case .finishing:
            title = String(localized: "Transcribing…")
            symbol = "waveform"
            dictationButton.isEnabled = false
            waiting = true
        case nil:
            title = String(localized: "Dictate")
            symbol = "mic.fill"
            dictationButton.isEnabled = true
        }
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        // Keep the icon on the strip's content line while the whole corner stays tappable.
        // Тримаємо значок на лінії вмісту смуги; натискається весь кут.
        let bottom = stripCenter.map { max(0, stripHeight - 3 - 2 * $0) } ?? 0
        config.contentInsets = .init(top: 0, leading: 0, bottom: bottom, trailing: 0)
        config.showsActivityIndicator = waiting
        config.baseForegroundColor = state.request == .recording ? .systemRed : Palette.micIdle
        dictationButton.configuration = config
        // A small dot marks dictation running on the device instead of the cloud.
        // Маленька крапка позначає диктування на пристрої, а не в хмарі.
        if localBadge.superview == nil {
            localBadge.backgroundColor = .systemOrange
            localBadge.layer.cornerRadius = 3
            localBadge.isUserInteractionEnabled = false
            dictationButton.addSubview(localBadge)
        }
        localBadge.isHidden = !state.local
        placeLocalBadge()
        dictationButton.accessibilityValue = state.local ? String(localized: "On-device mode") : nil
        dictationButton.accessibilityLabel = title
        dictationButton.accessibilityHint = !state.hasSession
            ? String(localized: "Opens Tacet to enable dictation.") : nil
    }
}
