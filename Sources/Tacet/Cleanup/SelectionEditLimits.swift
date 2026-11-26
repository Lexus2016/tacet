import Foundation

enum SelectionEditLimits {
    /// One voice edit or translation handles a selection of at most this many words; the gateway
    /// applies the same rule. Tacet is a dictation tool, not a document translator.
    /// Одна голосова правка чи переклад обробляє виділення щонайбільше з такої кількості слів;
    /// шлюз застосовує те саме правило. Tacet — інструмент диктування, а не перекладач документів.
    static let maximumWords = 1000
    static var tooLongMessage: String { String(localized: "The selected text is too long.") }

    /// Space-separated words; CJK text has no spaces, so two of its characters count as a word.
    /// Слова, розділені пробілами; у тексті CJK пробілів немає, тож два його символи рахуються як слово.
    static func words(in text: String) -> Int {
        let spaced = text.split(whereSeparator: \.isWhitespace).count
        let cjk = text.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: count + 1
            default: count
            }
        }
        return spaced + cjk / 2
    }

    static func isTooLong(_ selection: String) -> Bool {
        selection.utf8.count > maximumInputBytes || words(in: selection) > maximumWords
    }

    static let maximumInputBytes = 90 * 1024
    static let maximumInstructionBytes = 2 * 1024
    static let expandedThreshold = 8_000
    static let standardMaximumOutputTokens = 4_096
    static let maximumOutputTokens = 32_768
    static let expandedTimeout: TimeInterval = 150

    static func requiresExpandedBudget(_ selection: String) -> Bool {
        selection.utf8.count > expandedThreshold
    }

    static func outputTokens(for inputBytes: Int) -> Int {
        min(maximumOutputTokens, max(4_096, inputBytes / 2 + 2_048))
    }

    static func standardOutputTokens(for inputBytes: Int) -> Int {
        min(standardMaximumOutputTokens, 512 + inputBytes / 2)
    }

    static func standardEditOutputTokens(for inputBytes: Int) -> Int {
        // The completion budget covers reasoning and the replacement text.
        // Ліміт відповіді охоплює міркування моделі й текст заміни.
        min(standardMaximumOutputTokens, 2_048 + inputBytes / 2)
    }
}
