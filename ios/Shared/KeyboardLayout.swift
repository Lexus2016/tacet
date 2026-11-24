import Foundation

enum KeyboardLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en", ukrainian = "uk", german = "de", spanish = "es", french = "fr"
    case italian = "it", polish = "pl", portuguese = "pt", russian = "ru"

    static let defaults: [Self] = [.english, .ukrainian, .russian]

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
        }
    }

    var code: String {
        switch self {
        case .ukrainian: return "УК"
        case .russian: return "РУ"
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
        }
    }

    var letters: [String] {
        switch self {
        case .ukrainian: return ["йцукенгшщзхї", "фівапролджє", "ячсмитьбюґ"]
        case .german: return ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"]
        case .spanish: return ["qwertyuiop", "asdfghjklñ", "zxcvbnm"]
        case .french: return ["azertyuiop", "qsdfghjklm", "wxcvbn"]
        case .russian: return ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбюё"]
        case .english, .italian, .polish, .portuguese:
            return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        }
    }

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
        case .english, .ukrainian, .russian: return ""
        }
        return accented[letter] ?? ""
    }

    static func ordered(_ selection: [Self]) -> [Self] {
        let result = allCases.filter { selection.contains($0) }
        return result.isEmpty ? defaults : result
    }
}
