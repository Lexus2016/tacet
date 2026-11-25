import Foundation

actor KeyboardCompletionLexicon {
    enum Match: Sendable {
        case word, prefix([String]), none
    }

    private var lists: [KeyboardLayout: [String]] = [:]

    func match(for word: KeyboardWord, layout: KeyboardLayout) -> Match {
        guard word.canComplete, !Task.isCancelled else { return .none }
        let entries = vocabulary(for: layout)
        let prefix = word.completionPrefix
        if entries.contains(prefix) { return .word }
        let choices = word.completions(Array(entries.lazy.filter { $0.hasPrefix(prefix) }.prefix(6)))
        return choices.isEmpty ? .none : .prefix(choices)
    }

    private func vocabulary(for layout: KeyboardLayout) -> [String] {
        if let entries = lists[layout] { return entries }
        let url = Bundle.main.url(forResource: "completion-\(layout.rawValue)", withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let entries = text.split(whereSeparator: \.isNewline).map(String.init)
        lists[layout] = entries
        return entries
    }
}
