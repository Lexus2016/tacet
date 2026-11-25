import UIKit

private final class TypingKey: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: 0).contains(point)
    }
}

final class KeyboardController: UIInputViewController {
    private enum PortraitMetrics {
        static let height: CGFloat = 262
        static let top: CGFloat = 48
        static let gap: CGFloat = 10
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

    private struct Suggestions {
        let document: UUID
        let layout: KeyboardLayout
        let word: KeyboardWord
        let choices: [String]
    }

    private struct Trackpad {
        let document: UUID
        var anchor: CGPoint
    }

    private struct DictationButtonState: Equatable {
        let request: Request.State?
        let hasSession: Bool
    }

    private static var wakeRequest: WakeRequest?

    private enum KeyPage { case letters, numbers, extended }

    private let dictationButton = UIButton(configuration: .borderedProminent())
    private let statusLabel = UILabel()
    private let keyPreview = UILabel()
    private let suggestionBar = UIStackView()
    private let keys = UIStackView()
    private let globe = UIButton(configuration: .filled())
    private var layoutPicker: UIStackView?
    private var keyboardHeight: NSLayoutConstraint?
    private var topInset: NSLayoutConstraint?
    private var bottomInset: NSLayoutConstraint?
    private var suggestionBottom: NSLayoutConstraint?
    private var rowPadding = PortraitMetrics.gap / 2
    private var shiftButton: UIButton?
    private var letterButtons: [(UIButton, Character)] = []
    private var feedback: UIImpactFeedbackGenerator?
    private let checker = UITextChecker()
    private let lexicon = KeyboardCompletionLexicon()
    private lazy var dictionaries = UITextChecker.availableLanguages
    private var suggestionDividers: [UIView] = []
    private var suggestions: Suggestions?
    private var suggestionRefresh: Task<Void, Never>?
    private var suggestionsAfter = ContinuousClock.now
    private var touchedKeys: Set<ObjectIdentifier> = []
    private var lastEdit = ContinuousClock.now - .seconds(1)
    private var deleteRepeat: Task<Void, Never>?
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
        manualShift = false
        refreshAutomaticCase()
        buildKeys()
        if #available(iOS 17.5, *) {
            feedback = UIImpactFeedbackGenerator(style: .medium, view: view)
        } else {
            feedback = UIImpactFeedbackGenerator(style: .medium)
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

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        closeLayoutPicker()
        feedback = nil
        pollTask?.cancel()
        pollTask = nil
        cancelPending()
        clearPreview()
        touchedKeys.removeAll()
        endDeleteRepeat()
        endTrackpad()
        verticalCursorMove?.cancel()
        cancelSuggestionRefresh()
        displaySuggestions(nil)
        super.viewWillDisappear(animated)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globe.isHidden = !needsInputModeSwitchKey
        let landscape = view.bounds.width > 480
        let target: CGFloat = landscape ? 229 : PortraitMetrics.height
        if keyboardHeight?.constant != target { keyboardHeight?.constant = target }
        let padding: CGFloat = landscape ? 3 : PortraitMetrics.gap / 2
        let inset = (landscape ? 27 : PortraitMetrics.top) - padding
        if topInset?.constant != inset { topInset?.constant = inset }
        if rowPadding != padding {
            rowPadding = padding
            bottomInset?.constant = padding - 8
            suggestionBottom?.constant = padding - 3
            for case let row as UIStackView in keys.arrangedSubviews {
                for case let key as UIButton in row.arrangedSubviews {
                    key.configuration?.background.backgroundInsets = keyBackgroundInsets
                }
            }
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if let pending, pending.field != Field(textDocumentProxy) {
            cancelPending()
            showError(String(localized: "The text field changed. Dictate again here."))
        }
        refreshCaseAfterExternalChange()
        scheduleSuggestions()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshCaseAfterExternalChange()
        scheduleSuggestions()
    }

    private func configureView() {
        keys.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keys)
        let height = view.heightAnchor.constraint(equalToConstant: PortraitMetrics.height)
        height.priority = .defaultHigh
        height.isActive = true
        keyboardHeight = height
        let top = keys.topAnchor.constraint(equalTo: view.topAnchor, constant: PortraitMetrics.top - rowPadding)
        let bottom = keys.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: rowPadding - 8)
        topInset = top
        bottomInset = bottom
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            top,
            bottom
        ])
        dictationButton.accessibilityIdentifier = "tacet-dictation"
        dictationButton.addTarget(self, action: #selector(dictationTapped), for: .touchUpInside)
        dictationButton.addTarget(self, action: #selector(keyFeedback), for: .touchDown)
        dictationButton.widthAnchor.constraint(equalToConstant: 45).isActive = true
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
            statusLabel.leadingAnchor.constraint(equalTo: keys.leadingAnchor, constant: 12),
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
    }

    private func configureSuggestionBar() {
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.distribution = .fillEqually
        suggestionBar.spacing = 0
        suggestionBar.isHidden = true
        view.addSubview(suggestionBar)
        let bottom = suggestionBar.bottomAnchor.constraint(equalTo: keys.topAnchor, constant: rowPadding - 3)
        suggestionBottom = bottom
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            bottom,
            suggestionBar.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
        ])
        for index in 0..<3 {
            let button = UIButton(type: .system)
            button.setTitleColor(Palette.caption, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 18, weight: index == 1 ? .semibold : .regular)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            button.accessibilityIdentifier = "tacet-suggestion-\(index)"
            button.accessibilityHint = String(localized: "Replaces the word you are typing.")
            button.addTarget(self, action: #selector(keyFeedback), for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.applySuggestion(at: index) }, for: .primaryActionTriggered)
            suggestionBar.addArrangedSubview(button)
            let divider = UIView()
            divider.isUserInteractionEnabled = false
            divider.backgroundColor = Palette.caption.withAlphaComponent(0.22)
            divider.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(divider)
            NSLayoutConstraint.activate([
                divider.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                divider.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                divider.heightAnchor.constraint(equalTo: button.heightAnchor, multiplier: 0.48),
                divider.widthAnchor.constraint(equalToConstant: 1),
            ])
            suggestionDividers.append(divider)
        }
    }

    private func scheduleSuggestions() {
        guard touchedKeys.isEmpty else { return }
        guard visible, page == .letters, pending == nil, trackpad == nil, deleteRepeat == nil,
              layoutPicker == nil else {
            cancelSuggestionRefresh()
            if suggestions != nil { displaySuggestions(nil) }
            return
        }
        suggestionsAfter = .now + .milliseconds(280)
        guard suggestionRefresh == nil else { return }
        suggestionRefresh = Task { [weak self] in
            while let due = self?.suggestionsAfter {
                do { try await Task.sleep(until: due, clock: .continuous) } catch { return }
                guard let self else { return }
                if due < suggestionsAfter { continue }
                await refreshSuggestions(when: due)
                guard !Task.isCancelled else { return }
                if due < suggestionsAfter { continue }
                suggestionRefresh = nil
                return
            }
        }
    }

    private func cancelSuggestionRefresh() {
        suggestionRefresh?.cancel()
        suggestionRefresh = nil
    }

    private func suggestionWord(in proxy: UITextDocumentProxy) -> KeyboardWord? {
        guard proxy.autocorrectionType != .no, proxy.spellCheckingType != .no, proxy.isSecureTextEntry != true else {
            return nil
        }
        switch proxy.keyboardType {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad:
            return nil
        default:
            return KeyboardWord(before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
                                selection: proxy.selectedText)
        }
    }

    private func refreshSuggestions(when due: ContinuousClock.Instant) async {
        guard touchedKeys.isEmpty else { return }
        let proxy = textDocumentProxy
        guard visible, page == .letters, pending == nil, trackpad == nil, deleteRepeat == nil,
              layoutPicker == nil, let word = suggestionWord(in: proxy)
        else {
            displaySuggestions(nil)
            return
        }

        let document = proxy.documentIdentifier
        let requestedLayout = layout
        var choices: [String] = []
        var wordIsKnown = false
        if word.canComplete {
            let match = await lexicon.match(for: word, layout: requestedLayout)
            guard !Task.isCancelled, visible, due == suggestionsAfter, touchedKeys.isEmpty,
                  pending == nil, trackpad == nil, deleteRepeat == nil,
                  requestedLayout == layout, document == textDocumentProxy.documentIdentifier else { return }
            switch match {
            case .word: wordIsKnown = true
            case .prefix(let completions): choices = completions
            case .none: break
            }
        }
        if !wordIsKnown, choices.isEmpty {
            choices = systemSuggestions(for: word)
        }
        displaySuggestions(choices.isEmpty ? nil : Suggestions(document: document, layout: requestedLayout,
                                  word: word, choices: [word.text] + Array(choices.prefix(2))))
    }

    private func systemSuggestions(for word: KeyboardWord) -> [String] {
        guard let language = KeyboardWord.dictionary(for: layout, in: dictionaries) else { return [] }
        let range = NSRange(location: 0, length: word.text.utf16.count)
        guard checker.rangeOfMisspelledWord(in: word.text, range: range, startingAt: 0,
                                             wrap: false, language: language) == range else { return [] }
        if word.canComplete {
            let candidates = checker.completions(forPartialWordRange: range, in: word.text, language: language) ?? []
            let completions = word.completions(candidates)
            if !completions.isEmpty { return completions }
        }
        return word.corrections(checker.guesses(forWordRange: range, in: word.text, language: language) ?? [])
    }

    private func displaySuggestions(_ options: Suggestions?) {
        suggestions = options
        let choices = options?.choices ?? []
        for (index, view) in suggestionBar.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            let title = choices.indices.contains(index) ? choices[index] : nil
            button.setTitle(index == 0 ? title.map { "“\($0)”" } : title, for: .normal)
            button.isEnabled = title != nil
            button.accessibilityElementsHidden = title == nil
            button.isHidden = title == nil
            suggestionDividers[index].isHidden = index >= choices.count - 1
        }
        suggestionBar.isHidden = options == nil || !statusLabel.isHidden || page != .letters || pending != nil || trackpad != nil
    }

    private func applySuggestion(at index: Int) {
        let proxy = textDocumentProxy
        guard pending == nil, page == .letters, let suggestions,
              suggestions.choices.indices.contains(index), suggestions.document == proxy.documentIdentifier,
              suggestions.layout == layout, suggestionWord(in: proxy) == suggestions.word
        else {
            scheduleSuggestions()
            return
        }
        let word = suggestions.word
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
                guard proxy.documentIdentifier == suggestions.document,
                      let moved = suggestionWord(in: proxy), moved.text == word.text, moved.trailing.isEmpty,
                      !moved.selected else { return }
            }
            for _ in word.text { proxy.deleteBackward() }
            proxy.insertText(replacement)
        }
        displaySuggestions(nil)
    }

    private func buildKeys() {
        touchedKeys.removeAll()
        latestTouch = nil
        letterButtons.removeAll()
        shiftButton = nil
        while let row = keys.arrangedSubviews.first { row.removeFromSuperview() }
        let rows: [String]
        switch page {
        case .letters: rows = layout.letters
        case .numbers: rows = ["1234567890", "-/:;()₴&@“", ".,?!'"]
        case .extended: rows = ["[]{}#%^*+=", "_\\|~<>€£¥•", "…!?“”"]
        }
        let letters = page == .letters
        for (index, characters) in rows.enumerated() {
            let row = UIStackView()
            row.distribution = .fillEqually
            row.spacing = 4
            var leadingControl: UIButton?
            var delete: UIButton?
            var firstLetter: UIButton?
            if letters && layout == .english && index == 1 {
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
            for character in characters {
                let title = uppercase && letters ? character.uppercased() : String(character)
                let button = key(title, showsPreview: true) { [weak self] in
                    guard let self else { return }
                    insertLetter(uppercase && letters ? character.uppercased() : String(character))
                }
                if letters { letterButtons.append((button, character)) }
                let variants = letters ? layout.alternatives(for: character) : punctuationAlternatives(for: character)
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
                let button = key("", symbol: "delete.left", accessibility: String(localized: "Delete"),
                                 isModifier: true) { [weak self] in
                    self?.deleteLetter()
                }
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:)))
                hold.minimumPressDuration = 0.36
                button.addGestureRecognizer(hold)
                delete = button
                row.addArrangedSubview(button)
            }
            if index == 2, (!letters || layout == .english), let firstLetter, let leadingControl, let delete {
                row.distribution = .fill
                NSLayoutConstraint.activate(row.arrangedSubviews.filter { $0 !== firstLetter }.map { view in
                    view.widthAnchor.constraint(equalTo: firstLetter.widthAnchor,
                                                multiplier: view === leadingControl || view === delete ? 1.5 : 1)
                })
            }
            keys.addArrangedSubview(row)
        }
        let bottom = UIStackView()
        bottom.spacing = 4
        bottom.addArrangedSubview(globe)
        let numbers = key(letters ? "123" : (layout.isCyrillic ? "АБВ" : "ABC"),
                          isModifier: true) { [weak self] in
            guard let self else { return }
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
        bottom.addArrangedSubview(dictationButton)
        NSLayoutConstraint.activate([
            numbers.widthAnchor.constraint(equalToConstant: 46),
            language.widthAnchor.constraint(equalToConstant: 41),
            returnKey.widthAnchor.constraint(equalToConstant: 45)
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
        touchedKeys.removeAll()
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
        clearPreview()
        displaySuggestions(nil)
        layout = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "tacet.keyboardLayout")
        page = .letters
        manualShift = false
        refreshAutomaticCase()
        buildKeys()
    }

    private func insertLetter(_ text: String) {
        edit { $0.insertText(text) }
        guard page == .letters else { return }
        manualShift = false
        setUppercase(capitalization == .allCharacters)
    }

    private func insertBoundary(_ text: String) {
        let before = page == .letters && capitalization == .sentences
            ? textDocumentProxy.documentContextBeforeInput ?? "" : ""
        edit { $0.insertText(text) }
        guard page == .letters else { return }
        manualShift = false
        setUppercase(capitalization.startsUppercase(after: before + text))
    }

    private func deleteLetter() {
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
            let title = uppercase ? letter.uppercased() : String(letter)
            button.configuration?.title = title
            button.accessibilityLabel = title
        }
    }

    @objc private func showKeyPreview(_ button: UIButton) {
        guard latestTouch === button, let title = button.configuration?.title else { return }
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
        feedback?.impactOccurred(intensity: 0.434)
    }

    @objc private func keyTouched(_ button: UIButton) {
        guard trackpad == nil else { return }
        verticalCursorMove?.cancel()
        touchedKeys.insert(ObjectIdentifier(button))
        latestTouch = button
        if button is TypingKey { showKeyPreview(button) }
        else { clearPreview() }
        keyFeedback()
    }

    @objc private func keyTouchCancelled(_ button: UIButton) {
        touchedKeys.remove(ObjectIdentifier(button))
        scheduleSuggestions()
    }

    @objc private func holdDelete(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard trackpad == nil else { return }
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
                    let unit = KeyboardDeletion.unit(after: .now - start + .milliseconds(360))
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
                    if count > 0 { keyFeedback() }
                    let delay: Duration
                    switch unit {
                    case .character: delay = .milliseconds(84)
                    case .word: delay = .milliseconds(145)
                    case .sentence: delay = .milliseconds(205)
                    case .paragraph: delay = .milliseconds(260)
                    }
                    do { try await Task.sleep(for: delay) } catch { return }
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
            attributes.font = .systemFont(ofSize: isModifier ? 15 : 24, weight: .medium)
            return attributes
        }
        configuration.baseBackgroundColor = isModifier ? Palette.modifier : Palette.key
        configuration.baseForegroundColor = .label
        configuration.contentInsets = isModifier ? .init(top: 0, leading: 9, bottom: 0, trailing: 9) : .zero
        let button = showsPreview ? TypingKey(configuration: configuration) : UIButton(configuration: configuration)
        button.isExclusiveTouch = false
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            touchedKeys.remove(ObjectIdentifier(button))
            guard trackpad == nil else { return }
            let previewTitle = showsPreview && latestTouch === button ? button.configuration?.title : nil
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
        if suggestions != nil { displaySuggestions(nil) }
        scheduleSuggestions()
    }

    @objc private func dictationTapped() {
        guard trackpad == nil else { return }
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
                request.expires = Date().addingTimeInterval(DictationBridge.processingTimeout)
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
        if let selection, selection.prefix(DictationBridge.selectionLimit + 1).count > DictationBridge.selectionLimit {
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
            cancelPending()
            status = nil
            showError(error.localizedDescription)
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
                pending?.expires = Date().addingTimeInterval(DictationBridge.processingTimeout)
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
        let state = DictationButtonState(request: pending?.state, hasSession: status != nil)
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
        let hideSuggestions = !hideStatus || pending != nil || page != .letters || suggestions == nil || trackpad != nil
        if suggestionBar.isHidden != hideSuggestions { suggestionBar.isHidden = hideSuggestions }
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
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .fixed
        config.background.cornerRadius = 7
        config.background.backgroundInsets = keyBackgroundInsets
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        config.contentInsets = .zero
        config.showsActivityIndicator = waiting
        config.baseForegroundColor = .white
        config.baseBackgroundColor = state.request == .recording ? .systemRed : Palette.accent
        dictationButton.configuration = config
        dictationButton.accessibilityLabel = title
        dictationButton.accessibilityHint = !state.hasSession
            ? String(localized: "Opens Tacet to enable dictation.") : nil
    }
}
