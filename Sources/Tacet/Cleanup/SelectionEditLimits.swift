import Foundation

enum SelectionEditLimits {
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
