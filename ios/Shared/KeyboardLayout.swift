import Foundation

enum KeyboardLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en", ukrainian = "uk", german = "de", spanish = "es", french = "fr"
    case italian = "it", polish = "pl", portuguese = "pt", russian = "ru", czech = "cs"
    case chinesePinyin = "zh", hindi = "hi"

    static let defaults: [Self] = [
        .english, .ukrainian, .german, .spanish, .french, .italian, .portuguese, .russian, .czech
    ]

    var id: String { rawValue }

    var speechLocale: String {
        switch self {
        case .english: "en-US"
        case .ukrainian: "uk-UA"
        case .german: "de-DE"
        case .spanish: "es-ES"
        case .french: "fr-FR"
        case .italian: "it-IT"
        case .polish: "pl-PL"
        case .portuguese: "pt-PT"
        case .russian: "ru-RU"
        case .czech: "cs-CZ"
        case .chinesePinyin: "zh-CN"
        case .hindi: "hi-IN"
        }
    }

    var code: String {
        switch self {
        case .ukrainian: return "УК"
        case .russian: return "РУ"
        case .chinesePinyin: return "中"
        case .hindi: return "हि"
        default: return rawValue.uppercased()
        }
    }

    var name: String {
        switch self {
        case .english: return "English"
        case .ukrainian: return "Українська"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .polish: return "Polski"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .czech: return "Čeština"
        case .chinesePinyin: return "简体中文 · 拼音"
        case .hindi: return "हिन्दी"
        }
    }

    var space: String {
        switch self {
        case .english: return "space"
        case .ukrainian: return "пробіл"
        case .german: return "Leerzeichen"
        case .spanish: return "espacio"
        case .portuguese: return "espaço"
        case .french: return "espace"
        case .italian: return "spazio"
        case .polish: return "spacja"
        case .russian: return "пробел"
        case .czech: return "mezerník"
        case .chinesePinyin: return "空格"
        case .hindi: return "स्पेस"
        }
    }

    var letters: [String] {
        switch self {
        case .ukrainian: return ["йцукенгшщзхї", "фівапролджє", "ячсмитьбюґ"]
        case .german: return ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"]
        case .spanish: return ["qwertyuiop", "asdfghjklñ", "zxcvbnm"]
        case .french: return ["azertyuiop", "qsdfghjklm", "wxcvbn"]
        case .russian: return ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбюё"]
        case .czech: return ["qwertzuiop", "asdfghjkl", "yxcvbnm"]
        case .english, .italian, .polish, .portuguese, .chinesePinyin:
            return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .hindi:
            return Self.hindiKeys.map { $0.map(\.text).joined() }
        }
    }

    struct Key: Equatable {
        let text: String
        let shifted: String

        init(_ text: String, shifted: String? = nil) {
            self.text = text
            self.shifted = shifted ?? text.uppercased()
        }

        func output(shift: Bool) -> String { shift ? shifted : text }

        static func title(for text: String) -> String {
            switch text.unicodeScalars.first?.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return "◌" + text
            default: return text
            }
        }
    }

    var keys: [[Key]] {
        self == .hindi ? Self.hindiKeys : letters.map { row in row.map { Key(String($0)) } }
    }

    var usesPinyin: Bool { self == .chinesePinyin }
    var supportsAutomaticCapitalization: Bool { !usesPinyin && self != .hindi }

    // Explicit keys preserve individual matras and the halant on the InScript-style layout.
    // Окремі клавіші зберігають кожну матру й халант у розкладці на основі InScript.
    private static let hindiKeys: [[Key]] = [
        [.init("ौ", shifted: "औ"), .init("ै", shifted: "ऐ"), .init("ा", shifted: "आ"), .init("ी", shifted: "ई"),
         .init("ू", shifted: "ऊ"), .init("ब", shifted: "भ"), .init("ह", shifted: "ङ"), .init("ग", shifted: "घ"),
         .init("द", shifted: "ध"), .init("ज", shifted: "झ"), .init("ड", shifted: "ढ")],
        [.init("ो", shifted: "ओ"), .init("े", shifted: "ए"), .init("्", shifted: "अ"), .init("ि", shifted: "इ"),
         .init("ु", shifted: "उ"), .init("प", shifted: "फ"), .init("र", shifted: "ऋ"), .init("क", shifted: "ख"),
         .init("त", shifted: "थ"), .init("च", shifted: "छ"), .init("ट", shifted: "ठ")],
        [.init("ं", shifted: "ँ"), .init("म", shifted: "ण"), .init("न", shifted: "ञ"), .init("व", shifted: "ळ"),
         .init("ल", shifted: "़"), .init("स", shifted: "ः"), .init("य", shifted: "ृ"), .init("श", shifted: "ज्ञ"),
         .init("ष", shifted: "क्ष"), .init("।", shifted: "॥")]
    ]

    var isCyrillic: Bool { self == .ukrainian || self == .russian }

    func alternatives(for letter: Character) -> String {
        let accented: [Character: String]
        switch self {
        case .german: accented = ["s": "ß", "a": "ä", "o": "ö", "u": "ü"]
        case .spanish: accented = ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "úü", "n": "ñ"]
        case .french: accented = ["a": "àâæ", "c": "ç", "e": "éèêë", "i": "îï", "o": "ôœ", "u": "ùûü", "y": "ÿ"]
        case .italian: accented = ["a": "à", "e": "èé", "i": "ì", "o": "òó", "u": "ù"]
        case .polish: accented = ["a": "ą", "c": "ć", "e": "ę", "l": "ł", "n": "ń", "o": "ó", "s": "ś", "z": "źż"]
        case .portuguese: accented = ["a": "áàâã", "c": "ç", "e": "éê", "i": "í", "o": "óôõ", "u": "úü"]
        case .czech:
            accented = ["a": "á", "c": "č", "d": "ď", "e": "ěé", "i": "í", "n": "ň",
                        "o": "ó", "r": "ř", "s": "š", "t": "ť", "u": "ůú", "y": "ý", "z": "ž"]
        case .english, .ukrainian, .russian, .chinesePinyin, .hindi: return ""
        }
        return accented[letter] ?? ""
    }

    static func ordered(_ selection: [Self]) -> [Self] {
        let result = allCases.filter { selection.contains($0) }
        return result.isEmpty ? defaults : result
    }
}
