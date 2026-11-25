import Foundation

actor KeyboardCompletionLexicon {
    struct Match: Sendable {
        let known: Bool
        let completions: [String]
        /// Vocabulary words a typo away from an unknown word.
        /// Слова словника на відстані одруківки від невідомого слова.
        let corrections: [String]
    }

    private struct Vocabulary {
        let words: Set<String>
        let byInitial: [Character: [String]]
        let letters: [[Character]]

        init(_ entries: [String]) {
            var words = Set<String>()
            var buckets: [Character: [String]] = [:]
            for entry in entries {
                let word = KeyboardWord.completionKey(entry)
                guard let first = word.first, words.insert(word).inserted else { continue }
                buckets[first, default: []].append(word)
            }
            self.words = words
            byInitial = buckets
            letters = entries.map { Array(KeyboardWord.completionKey($0)) }
        }
    }

    private var lists: [KeyboardLayout: Vocabulary] = [:]

    func prepare(_ layout: KeyboardLayout) {
        _ = vocabulary(for: layout)
    }

    func match(for word: KeyboardWord, layout: KeyboardLayout) -> Match {
        guard !Task.isCancelled else { return Match(known: false, completions: [], corrections: []) }
        let entries = vocabulary(for: layout)
        let prefix = word.completionPrefix
        let candidates = prefix.first.flatMap { entries.byInitial[$0] } ?? []
        let known = entries.words.contains(prefix)
        return Match(known: known,
                     completions: word.completions(Array(candidates.lazy.filter { $0.hasPrefix(prefix) }.prefix(8))),
                     corrections: known ? [] : word.nearby(in: entries.letters))
    }

    private func vocabulary(for layout: KeyboardLayout) -> Vocabulary {
        if let entries = lists[layout] { return entries }
        let url = Bundle.main.url(forResource: "completion-\(layout.rawValue)", withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let entries = Vocabulary(text.split(whereSeparator: \.isNewline).map(String.init))
        lists[layout] = entries
        return entries
    }
}

actor KeyboardPinyinLexicon {
    private var dictionary: KeyboardPinyinDictionary?

    func prepare() {
        guard dictionary == nil else { return }
        let url = Bundle.main.url(forResource: "pinyin-zh", withExtension: "txt")
        let contents = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        dictionary = KeyboardPinyinDictionary(contents: contents)
    }

    func candidates(for pinyin: String) -> [String] {
        guard !Task.isCancelled else { return [] }
        prepare()
        return dictionary?.candidates(for: pinyin) ?? []
    }
}
