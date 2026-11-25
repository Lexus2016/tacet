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
        !selected && trailing.isEmpty && text.count >= 3
    }

    var completionPrefix: String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    func completions(_ candidates: [String]) -> [String] {
        guard canComplete else { return [] }
        let prefix = completionPrefix
        let length = prefix.count
        let matches = candidates.lazy.compactMap { candidate -> String? in
            let normalized = candidate.lowercased().replacingOccurrences(of: "’", with: "'")
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

    private static func isNearby(_ original: [Character], _ candidate: [Character], limit: Int) -> Bool {
        guard abs(original.count - candidate.count) <= limit else { return false }
        if original.count == candidate.count {
            let mismatches = original.indices.filter { original[$0] != candidate[$0] }
            if mismatches.count == 2, mismatches[1] == mismatches[0] + 1,
               original[mismatches[0]] == candidate[mismatches[1]],
               original[mismatches[1]] == candidate[mismatches[0]] {
                return true
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
        return previous[candidate.count] <= limit
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

    static func unit(after held: Duration) -> Unit {
        if held >= .seconds(4) { return .paragraph }
        if held >= .milliseconds(2_700) { return .sentence }
        if held >= .milliseconds(1_400) { return .word }
        return .character
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
