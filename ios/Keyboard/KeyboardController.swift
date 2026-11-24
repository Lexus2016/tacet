import UIKit

final class KeyboardController: UIInputViewController {
    private enum Palette {
        static let background = UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        static let key = UIColor(red: 0.23, green: 0.28, blue: 0.36, alpha: 1)
        static let modifier = UIColor(red: 0.17, green: 0.21, blue: 0.28, alpha: 1)
        static let accent = UIColor(red: 0.18, green: 0.42, blue: 0.72, alpha: 1)
        static let caption = UIColor(red: 0.78, green: 0.84, blue: 0.92, alpha: 1)
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
        enum State { case starting, recording, finishing }
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

    private static var wakeRequest: WakeRequest?

    private enum KeyPage { case letters, numbers, extended }

    private let dictationButton = UIButton(configuration: .borderedProminent())
    private let statusLabel = UILabel()
    private let keyPreview = UILabel()
    private let keys = UIStackView()
    private let globe = UIButton(configuration: .filled())
    private var keyboardHeight: NSLayoutConstraint?
    private var topInset: NSLayoutConstraint?
    private var status: DictationBridge.Status?
    private var pending: Request?
    private var pollTask: Task<Void, Never>?
    private var errorMessage: String?
    private var errorUntil = Date.distantPast
    private var enabledLayouts = KeyboardLayout.defaults
    private var layout = KeyboardLayout(rawValue: UserDefaults.standard.string(forKey: "tacet.keyboardLayout") ?? "en") ?? .english
    private var page = KeyPage.letters
    private var uppercase = false
    private var visible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        refreshLayouts()
        buildKeys()
        poll()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                guard let self else { return }
                poll()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        pollTask?.cancel()
        pollTask = nil
        cancelPending()
        keyPreview.isHidden = true
        super.viewWillDisappear(animated)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globe.isHidden = !needsInputModeSwitchKey
        let landscape = view.bounds.width > 480
        let target: CGFloat = landscape ? 229 : 298
        if keyboardHeight?.constant != target { keyboardHeight?.constant = target }
        let inset: CGFloat = landscape ? 27 : 35
        if topInset?.constant != inset { topInset?.constant = inset }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if let pending, pending.field != Field(textDocumentProxy) {
            cancelPending()
            showError(String(localized: "The text field changed. Dictate again here."))
        }
    }

    private func configureView() {
        view.backgroundColor = Palette.background
        keys.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keys)
        let height = view.heightAnchor.constraint(equalToConstant: 298)
        height.priority = .defaultHigh
        height.isActive = true
        keyboardHeight = height
        let top = keys.topAnchor.constraint(equalTo: view.topAnchor, constant: 35)
        topInset = top
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            top,
            keys.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        dictationButton.accessibilityIdentifier = "tacet-dictation"
        dictationButton.addTarget(self, action: #selector(dictationTapped), for: .touchUpInside)
        dictationButton.widthAnchor.constraint(equalToConstant: 45).isActive = true
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = Palette.caption
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.accessibilityIdentifier = "tacet-dictation-status"
        statusLabel.isHidden = true
        statusLabel.numberOfLines = 2
        statusLabel.backgroundColor = Palette.background
        statusLabel.layer.cornerRadius = 9
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: keys.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: keys.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: keys.trailingAnchor, constant: -12),
            statusLabel.heightAnchor.constraint(equalToConstant: 38)
        ])
        keyPreview.textAlignment = .center
        keyPreview.textColor = .white
        keyPreview.font = .systemFont(ofSize: 32, weight: .semibold)
        keyPreview.backgroundColor = Palette.accent
        keyPreview.layer.cornerRadius = 10
        keyPreview.clipsToBounds = true
        keyPreview.isAccessibilityElement = false
        keyPreview.isUserInteractionEnabled = false
        keyPreview.isHidden = true
        view.addSubview(keyPreview)
        keys.axis = .vertical
        keys.distribution = .fillEqually
        keys.spacing = 6
        globe.configuration?.image = UIImage(systemName: "globe")
        globe.configuration?.baseBackgroundColor = Palette.modifier
        globe.configuration?.baseForegroundColor = .white
        globe.accessibilityLabel = String(localized: "Switch keyboard")
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let globeWidth = globe.widthAnchor.constraint(equalToConstant: 40)
        globeWidth.priority = .defaultHigh
        globeWidth.isActive = true
    }

    private func buildKeys() {
        keyPreview.isHidden = true
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
                        uppercase.toggle()
                        buildKeys()
                    }
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
                let button = key(title) { [weak self] in
                    self?.insertLetter(title)
                }
                button.addTarget(self, action: #selector(showKeyPreview(_:)), for: [.touchDown, .touchDragEnter])
                button.addTarget(self, action: #selector(hideKeyPreview),
                                 for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
                let variants = letters ? layout.alternatives(for: character) : punctuationAlternatives(for: character)
                if !variants.isEmpty {
                    button.menu = UIMenu(children: variants.map { variant in
                        let text = uppercase && letters ? variant.uppercased() : String(variant)
                        return UIAction(title: text) { [weak self] _ in self?.insertLetter(text) }
                    })
                }
                if firstLetter == nil { firstLetter = button }
                row.addArrangedSubview(button)
            }
            if index == 2 {
                let button = key("", symbol: "delete.left", accessibility: String(localized: "Delete"),
                                 isModifier: true) { [weak self] in
                    self?.edit { $0.deleteBackward() }
                }
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
            uppercase = false
            buildKeys()
        }
        bottom.addArrangedSubview(numbers)
        let language = key(layout.code, accessibility: String(localized: "Keyboard language"), isModifier: true) { [weak self] in
            guard let self, let current = enabledLayouts.firstIndex(of: layout) else { return }
            setLanguage(enabledLayouts[(current + 1) % enabledLayouts.count])
        }
        language.accessibilityValue = layout.name
        language.isEnabled = enabledLayouts.count > 1
        language.menu = UIMenu(title: String(localized: "Keyboard language"), children: enabledLayouts.map { choice in
            UIAction(title: choice.name, state: layout == choice ? .on : .off) { [weak self] _ in self?.setLanguage(choice) }
        })
        bottom.addArrangedSubview(language)
        let space = key(layout.space, accessibility: String(localized: "Space"), isModifier: true) { [weak self] in
            self?.edit { $0.insertText(" ") }
        }
        space.configuration?.baseBackgroundColor = Palette.key
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(space)
        let returnKey = key("", symbol: "return", accessibility: String(localized: "Return"),
                            isModifier: true) { [weak self] in
            self?.edit { $0.insertText("\n") }
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
    }

    private func refreshLayouts() {
        if let saved = try? DictationBridge.keyboardLayouts() {
            enabledLayouts = KeyboardLayout.ordered(saved)
        }
        if !enabledLayouts.contains(layout) { layout = enabledLayouts[0] }
    }

    private func setLanguage(_ selected: KeyboardLayout) {
        layout = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "tacet.keyboardLayout")
        page = .letters
        uppercase = false
        buildKeys()
    }

    private func insertLetter(_ text: String) {
        edit { $0.insertText(text) }
        if uppercase && page == .letters {
            uppercase = false
            buildKeys()
        }
    }

    @objc private func showKeyPreview(_ button: UIButton) {
        guard let title = button.configuration?.title else { return }
        let key = button.convert(button.bounds, to: view)
        let width = max(50, key.width + 12)
        let height = min(60, max(43, key.height))
        let left = min(max(key.midX - width / 2, 3), view.bounds.width - width - 3)
        keyPreview.frame = CGRect(x: left, y: max(1, key.minY - height + 13), width: width, height: height)
        keyPreview.text = title
        keyPreview.isHidden = false
    }

    @objc private func hideKeyPreview() {
        keyPreview.isHidden = true
    }

    private func punctuationAlternatives(for character: Character) -> String {
        guard layout == .spanish else { return "" }
        if character == "?" { return "¿" }
        if character == "!" { return "¡" }
        return ""
    }

    private func key(_ title: String, symbol: String? = nil, accessibility: String? = nil,
                     isModifier: Bool = false, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 7
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
        configuration.baseForegroundColor = .white
        configuration.contentInsets = isModifier ? .init(top: 0, leading: 9, bottom: 0, trailing: 9) : .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = accessibility ?? title
        return button
    }

    private func edit(_ action: (UITextDocumentProxy) -> Void) {
        Self.wakeRequest = nil
        cancelPending()
        action(textDocumentProxy)
    }

    @objc private func dictationTapped() {
        guard hasFullAccess else {
            showError(String(localized: "Allow Full Access in Settings for dictation."))
            return
        }
        do {
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
        try DictationBridge.send(.init(session: request.session, request: request.id, action: .start, layout: layout))
        pending = request
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

    private func poll() {
        guard visible else { return }
        guard hasFullAccess else {
            if pending != nil { cancelPending() }
            status = nil
            renderState()
            return
        }
        do {
            status = try DictationBridge.status().flatMap { $0.expires > Date() ? $0 : nil }
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
            if status.phase == .result, let text = status.text, !text.isEmpty {
                textDocumentProxy.insertText(text)
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
        let title: String
        let symbol: String
        var waiting = false
        switch pending?.state {
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
            dictationButton.isEnabled = pending == nil
        }
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .fixed
        config.background.cornerRadius = 7
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        config.contentInsets = .zero
        config.showsActivityIndicator = waiting
        config.baseForegroundColor = .white
        config.baseBackgroundColor = pending?.state == .recording ? .systemRed : Palette.accent
        dictationButton.configuration = config
        dictationButton.accessibilityLabel = title
        dictationButton.accessibilityHint = status == nil
            ? String(localized: "Opens Tacet to enable dictation.") : nil
        if let errorMessage, errorUntil > Date() {
            statusLabel.text = errorMessage
        } else {
            statusLabel.text = nil
        }
        statusLabel.isHidden = statusLabel.text == nil
    }
}
