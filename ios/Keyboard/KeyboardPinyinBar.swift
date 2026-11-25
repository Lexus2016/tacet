import UIKit

final class KeyboardPinyinBar: UIScrollView {
    struct Choice: Equatable {
        let composition: String
        let candidate: String?
    }

    var onChoice: ((Choice) -> Void)?
    var onTouch: (() -> Void)?

    private let stack = UIStackView()
    private var choices: [Choice] = []
    private var pressed: [Int: Choice] = [:]

    init() {
        super.init(frame: .zero)
        isHidden = true
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        isDirectionalLockEnabled = true
        delaysContentTouches = false
        contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
            leftEdgeEffect.isHidden = true
            rightEdgeEffect.isHidden = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    func display(_ composition: String, candidates: [String]) {
        let updated = composition.isEmpty ? [] : [Choice(composition: composition, candidate: nil)]
            + candidates.map { Choice(composition: composition, candidate: $0) }
        guard choices != updated else { return }
        if choices.first?.composition != composition { setContentOffset(.zero, animated: false) }
        choices = updated
        for index in stack.arrangedSubviews.count..<max(stack.arrangedSubviews.count, updated.count) {
            stack.addArrangedSubview(makeButton(index: index))
        }
        for (index, view) in stack.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            let available = updated.indices.contains(index)
            button.isHidden = !available
            if available {
                let choice = updated[index]
                let title = choice.candidate ?? "“\(choice.composition)”"
                if button.configuration?.title != title { button.configuration?.title = title }
            } else {
                button.configuration?.title = nil
            }
        }
    }

    private func makeButton(index: Int) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .init(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.baseForegroundColor = index == 0 ? .secondaryLabel : .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var adjusted = attributes
            adjusted.font = .systemFont(ofSize: 18, weight: index == 1 ? .semibold : .regular)
            return adjusted
        }
        button.configuration = configuration
        button.accessibilityIdentifier = "tacet-pinyin-\(index)"
        button.accessibilityHint = index == 0 ? String(localized: "Insert the Pinyin as typed.")
            : String(localized: "Insert this Chinese candidate.")
        button.addAction(UIAction { [weak self] _ in self?.startPress(at: index) }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.pressed[index] = nil }, for: [.touchUpOutside, .touchCancel])
        button.addAction(UIAction { [weak self] _ in self?.finishPress(at: index) }, for: .primaryActionTriggered)
        return button
    }

    private func startPress(at index: Int) {
        pressed[index] = choices.indices.contains(index) ? choices[index] : nil
        onTouch?()
    }

    private func finishPress(at index: Int) {
        if let choice = pressed.removeValue(forKey: index) { onChoice?(choice) }
        else if choices.indices.contains(index) { onChoice?(choices[index]) }
    }
}
