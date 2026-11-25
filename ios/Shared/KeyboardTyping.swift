import Foundation

enum KeyboardCapitalization {
    case none, sentences, words, allCharacters

    func startsUppercase(after preceding: String) -> Bool {
        switch self {
        case .none: return false
        case .allCharacters: return true
        case .words: return preceding.last?.isWhitespace != false
        case .sentences:
            let reversed = preceding.reversed().drop(while: { "\"“‘«([{".contains($0) })
            let whitespace = reversed.prefix(while: \.isWhitespace)
            if whitespace.contains(where: \.isNewline) { return true }
            let content = reversed.dropFirst(whitespace.count)
            guard let last = content.first else { return true }
            guard !whitespace.isEmpty else { return false }
            let terminal = content.drop(while: { "”’»\")]}".contains($0) }).first ?? last
            return ".!?…".contains(terminal)
        }
    }
}

struct KeyboardPinyinComposition {
    static let maximumLength = 32
    private(set) var text = ""

    static func letter(_ input: String) -> String? {
        let bytes = input.utf8
        guard bytes.count == 1, let value = bytes.first,
              (65...90).contains(value) || (97...122).contains(value) else { return nil }
        return input.lowercased()
    }

    mutating func append(_ letter: String) {
        guard text.count < Self.maximumLength, let letter = Self.letter(letter) else { return }
        text += letter
    }

    mutating func deleteBackward() {
        if !text.isEmpty { text.removeLast() }
    }
}

struct KeyboardPinyinDictionary: Sendable {
    static let maximumCandidates = 16
    private let table: [String: [String]]

    init(contents: String) {
        var table: [String: [String]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "\t", maxSplits: 1)
            guard pair.count == 2, pair[0].utf8.allSatisfy({ (97...122).contains($0) }),
                  pair[0].utf8.count <= KeyboardPinyinComposition.maximumLength else { continue }
            let syllables = String(pair[0])
            let candidate = String(pair[1])
            if table[syllables, default: []].count < Self.maximumCandidates,
               !table[syllables, default: []].contains(candidate) {
                table[syllables, default: []].append(candidate)
            }
        }
        self.table = table
    }

    func candidates(for pinyin: String) -> [String] { table[pinyin] ?? [] }
}

struct KeyboardWord: Equatable, Sendable {
    let text: String
    let addsSpace: Bool
    let selected: Bool
    let trailing: String

    init?(before: String?, after: String?, selection: String?) {
        if let selection, !selection.isEmpty {
            guard selection.prefix(49).count < 49, selection.first?.isLetter == true,
                  selection.last?.isLetter == true, selection.allSatisfy(Self.isWordCharacter),
                  before?.last.map(Self.isWordCharacter) != true, after?.first.map(Self.isWordCharacter) != true
            else { return nil }
            text = selection
            selected = true
            trailing = ""
            addsSpace = false
            return
        }
        let reversed = (before ?? "").reversed().prefix(49).prefix(while: Self.isWordCharacter)
        let right = (after ?? "").prefix(49).prefix(while: Self.isWordCharacter)
        guard reversed.count + right.count < 49 else { return nil }
        let left = String(reversed.reversed().drop(while: { !$0.isLetter }))
        let trailing = String(right.reversed().drop(while: { !$0.isLetter }).reversed())
        let word = left + trailing
        guard word.first?.isLetter == true, word.last?.isLetter == true else { return nil }
        text = word
        self.trailing = trailing
        selected = false
        addsSpace = trailing.isEmpty && after?.isEmpty != false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’" || character == "-" || character == "ʼ"
    }

    var canComplete: Bool {
        !selected && trailing.isEmpty
    }

    var completionPrefix: String {
        Self.completionKey(text)
    }

    static func completionKey(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
    }

    // Like the system keyboard, complete the word around the caret wherever the caret sits.
    // Як системна клавіатура, доповнюємо слово біля курсора, де б курсор не стояв.
    func completions(_ candidates: [String]) -> [String] {
        let prefix = completionPrefix
        let length = prefix.count
        let matches = candidates.lazy.compactMap { candidate -> String? in
            let normalized = Self.completionKey(candidate)
            guard normalized.hasPrefix(prefix), normalized.count > length,
                  normalized.allSatisfy(Self.isWordCharacter) else { return nil }
            return text + candidate.dropFirst(length)
        }
        return options(Array(matches.prefix(6)))
    }

    func options(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word != text, seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
            if result.count == 3 { break }
        }
        return result
    }

    func corrections(_ candidates: [String]) -> [String] {
        let original = Array(text.lowercased())
        guard original.count >= 3 else { return [] }
        let limit = original.count >= 5 ? 2 : 1
        let nearby = candidates.prefix(12).filter { candidate in
            let letters = Array(candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            return !letters.isEmpty && letters.allSatisfy(Self.isWordCharacter)
                && Self.isNearby(original, letters, limit: limit)
        }
        return options(Array(nearby))
    }

    /// Vocabulary words one typo away from the typed word (two for words of five letters or more):
    /// closest first, vocabulary order within the same distance, in the typed word's letter case.
    /// Слова словника на відстані однієї одруківки від набраного (двох — для слів від п'яти літер):
    /// спершу найближчі, за однакової відстані — у порядку словника, у регістрі набраного слова.
    func nearby(in vocabulary: [[Character]]) -> [String] {
        let original = Array(completionPrefix)
        guard original.count >= 3 else { return [] }
        let limit = original.count >= 5 ? 2 : 1
        var ranked: [(distance: Int, rank: Int, letters: [Character])] = []
        for (rank, candidate) in vocabulary.enumerated() {
            guard let distance = Self.distance(original, candidate, limit: limit), distance > 0 else { continue }
            ranked.append((distance, rank, candidate))
        }
        ranked.sort { ($0.distance, $0.rank) < ($1.distance, $1.rank) }
        let uppercase = text.count > 1 && text.allSatisfy { !$0.isLowercase }
        let capitalized = text.first?.isUppercase == true
        return options(ranked.prefix(6).map { entry in
            let word = String(entry.letters)
            if uppercase { return word.uppercased() }
            return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
        })
    }

    private static func isNearby(_ original: [Character], _ candidate: [Character], limit: Int) -> Bool {
        distance(original, candidate, limit: limit) != nil
    }

    private static func distance(_ original: [Character], _ candidate: [Character], limit: Int) -> Int? {
        guard abs(original.count - candidate.count) <= limit else { return nil }
        if original.count == candidate.count {
            let mismatches = original.indices.filter { original[$0] != candidate[$0] }
            if mismatches.count == 2, mismatches[1] == mismatches[0] + 1,
               original[mismatches[0]] == candidate[mismatches[1]],
               original[mismatches[1]] == candidate[mismatches[0]] {
                return 1
            }
        }
        var previous = Array(0...candidate.count)
        for (index, letter) in original.enumerated() {
            var current = [index + 1]
            for (column, replacement) in candidate.enumerated() {
                current.append(min(current[column] + 1, previous[column + 1] + 1,
                                   previous[column] + (letter == replacement ? 0 : 1)))
            }
            previous = current
        }
        return previous[candidate.count] <= limit ? previous[candidate.count] : nil
    }

    func replacement(_ choice: String) -> String {
        choice + (addsSpace ? " " : "")
    }

    static func dictionary(for layout: KeyboardLayout, in languages: [String]) -> String? {
        let locale = layout.speechLocale.lowercased()
        let normalize: (String) -> String = { $0.lowercased().replacingOccurrences(of: "_", with: "-") }
        return languages.first { normalize($0) == locale }
            ?? languages.first { normalize($0).prefix(while: { $0 != "-" }) == layout.rawValue }
    }
}

enum KeyboardDeletion {
    enum Unit {
        case character, word, sentence, paragraph
    }

    /// Hold time before the first repeat; the first character is deleted on touch-down.
    /// Час утримання до першого повтору; перший символ видаляється одразу при дотику.
    static let holdSeconds: TimeInterval = 0.32

    static func unit(after held: Duration) -> Unit {
        if held >= .milliseconds(3_800) { return .paragraph }
        if held >= .milliseconds(2_500) { return .sentence }
        if held >= .milliseconds(1_200) { return .word }
        return .character
    }

    static func interval(for unit: Unit) -> Duration {
        switch unit {
        case .character: .milliseconds(55)
        case .word: .milliseconds(110)
        case .sentence: .milliseconds(170)
        case .paragraph: .milliseconds(230)
        }
    }

    static func count(in before: String, unit: Unit) -> Int {
        if unit == .character { return before.isEmpty ? 0 : 1 }
        let tail = before.reversed().prefix(64)
        let isBoundary: (Character) -> Bool
        switch unit {
        case .character: return before.isEmpty ? 0 : 1
        case .word: isBoundary = { $0.isWhitespace || $0.isPunctuation }
        case .sentence: isBoundary = { $0.isNewline || ".!?…".contains($0) }
        case .paragraph: isBoundary = { $0.isNewline }
        }
        let leading = tail.prefix { $0.isWhitespace || isBoundary($0) }
        let body = tail.dropFirst(leading.count).prefix { !isBoundary($0) }
        return leading.count + body.count
    }
}

enum KeyboardCursor {
    static func horizontalOffset(before: String?, after: String?, steps: Int) -> Int {
        if steps < 0 { return -(before ?? "").suffix(-steps).utf16.count }
        return (after ?? "").prefix(steps).utf16.count
    }

    static func verticalOffset(before: String, after: String, down: Bool) -> Int {
        let column = self.column(before: before)
        if down, let lineBreak = after.firstIndex(where: \.isNewline) {
            let nextStart = after.index(after: lineBreak)
            let nextLine = after[nextStart...].prefix { !$0.isNewline }
            return after[..<nextStart].utf16.count + nextLine.prefix(column).utf16.count
        }
        if !down, let lineBreak = before.lastIndex(where: \.isNewline) {
            let previousLine = before[..<lineBreak].suffix(from: startOfLine(in: before[..<lineBreak]))
            return -(before[lineBreak...].utf16.count + previousLine.dropFirst(column).utf16.count)
        }
        return 0
    }

    static func column(before: String) -> Int {
        before[startOfLine(in: before[...])...].count
    }

    static func offset(toColumn column: Int, before: String, after: String) -> Int {
        let left = before[startOfLine(in: before[...])...]
        let steps = column - left.count
        let right = after.prefix { !$0.isNewline }
        if steps < 0 { return -left.suffix(-steps).utf16.count }
        return right.prefix(steps).utf16.count
    }

    private static func startOfLine(in text: Substring) -> String.Index {
        guard let lineBreak = text.lastIndex(where: \.isNewline) else { return text.startIndex }
        return text.index(after: lineBreak)
    }
}

enum KeyboardPreview {
    static func frame(above key: CGRect, inside bounds: CGRect) -> CGRect {
        let width = min(max(52, key.width + 24), max(0, bounds.width - 6))
        let height = min(68, max(58, key.height + 22), max(0, bounds.height - 2))
        let left = min(max(key.midX - width / 2, bounds.minX + 3), bounds.maxX - width - 3)
        let top = min(max(bounds.minY + 1, key.minY - height - 3), bounds.maxY - height - 1)
        return CGRect(x: left, y: top, width: width, height: height)
    }
}
