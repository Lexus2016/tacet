import Foundation
import NaturalLanguage

/// Everything about picking the language of a single dictation.
///
/// A dictation app must not require the user to switch a language setting when
/// they switch chats. The cloud engine detects the language per request, and
/// Ukrainian/Russian is the one pair where detection is genuinely unreliable:
/// the two languages share most of their vocabulary and the Cyrillic script.
/// Script markers give a free, deterministic signal, and a second decode is
/// only run when the signal is missing or contradicts the engine.
enum LanguagePolicy {
    private static let ukrainianMarkers = Set("іїєґІЇЄҐ")
    private static let russianMarkers = Set("ыэъёЫЭЪЁ")

    /// Returns "uk", "ru" or nil when the text carries no decisive marker.
    static func cyrillicVerdict(_ text: String) -> String? {
        var ukrainian = 0
        var russian = 0
        for character in text {
            if ukrainianMarkers.contains(character) { ukrainian += 1 }
            if russianMarkers.contains(character) { russian += 1 }
        }
        if russian > 0, ukrainian == 0 { return "ru" }
        if ukrainian > 0, russian == 0 { return "uk" }
        return nil
    }

    static func isCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Languages the script check can reason about.
    static func isConfusable(_ language: String?) -> Bool {
        guard let language else { return false }
        return ["uk", "ru", "be", "bg"].contains(language)
    }

    /// Scripts where a decisive letter overrides the engine's detection.
    static let cyrillicLanguages: Set<String> = ["uk", "ru", "be", "bg", "sr", "mk", "kk", "ky", "tg", "mn"]

    static func scriptMatches(_ language: String, _ text: String) -> Bool {
        cyrillicLanguages.contains(language) == isCyrillic(text)
    }

    /// The most likely confusion partner for an engine that is unsure.
    /// Not a claim that they sound alike — just where the extra check is worth
    /// one request.
    private static let siblings: [String: String] = [
        "uk": "ru", "ru": "uk", "be": "ru", "bg": "ru", "mk": "bg",
        "pl": "uk", "cs": "sk", "sk": "cs", "hr": "sr", "sl": "hr",
    ]

    /// The second language to try, or nil when a second decode would add
    /// nothing. `expected` is the language last used in this app.
    static func alternate(for transcript: Transcript, expected: String? = nil) -> String? {
        let detected = normalize(transcript.language)

        // Decisive script evidence: the detected language is confirmed, so a
        // second decode would only add cost and a chance to corrupt good text.
        if let verdict = cyrillicVerdict(transcript.text) {
            return verdict == detected ? nil : verdict
        }

        // The engine agrees with what this app usually dictates.
        if let expected, detected == expected {
            return nil
        }

        // Ambiguous text: the remembered language is the next strongest
        // evidence, as long as it writes the script we actually see.
        if let expected, scriptMatches(expected, transcript.text) {
            return expected
        }

        guard let detected, let sibling = siblings[detected], sibling != expected else {
            return nil
        }
        return sibling
    }

    /// Score used to choose between two decodes of the same audio. The engine
    /// score dominates; a transcript whose script contradicts the language it
    /// was requested in is penalised, because that is exactly the failure the
    /// second pass exists to catch.
    static func adjustedScore(_ transcript: Transcript, requested: String?) -> Double {
        var score = transcript.score
        if let requested, let verdict = cyrillicVerdict(transcript.text), verdict != requested {
            score -= 0.35
        }
        return score
    }

    static func pick(first: Transcript, second: Transcript, secondRequested: String) -> Transcript {
        let firstScore = adjustedScore(first, requested: normalize(first.language))
        let secondScore = adjustedScore(second, requested: secondRequested)
        return secondScore > firstScore ? second : first
    }

    // MARK: Normalisation

    private static let names: [String: String] = [
        "ukrainian": "uk", "russian": "ru", "english": "en", "german": "de",
        "spanish": "es", "french": "fr", "polish": "pl", "turkish": "tr",
        "italian": "it", "portuguese": "pt", "dutch": "nl", "czech": "cs",
        "slovak": "sk", "romanian": "ro", "bulgarian": "bg", "serbian": "sr",
        "croatian": "hr", "danish": "da", "swedish": "sv", "finnish": "fi",
        "norwegian": "no", "hungarian": "hu", "greek": "el", "hebrew": "he",
        "arabic": "ar", "japanese": "ja", "korean": "ko", "chinese": "zh",
        "hindi": "hi", "vietnamese": "vi", "indonesian": "id", "thai": "th",
    ]

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.count == 2 { return value }
        if let dash = value.firstIndex(of: "-") ?? value.firstIndex(of: "_") {
            return String(value[value.startIndex..<dash])
        }
        return names[value] ?? (value.count > 2 ? String(value.prefix(2)) : value)
    }

    static func knownLanguage(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty,
              let code = names[value] ?? Locale.Language(identifier: value).languageCode?.identifier,
              Locale.LanguageCode.isoLanguageCodes.contains(.init(code)) else { return nil }
        return code
    }
}

/// Text-based language identification for engines that do not report one
/// (Parakeet). On-device, instant, and only used for the label in History and
/// for the Cyrillic sanity check — never to override a decode.
enum TextLanguage {
    static func source(in text: String, reported: String?) -> String? {
        LanguagePolicy.knownLanguage(reported) ?? detect(text) ?? LanguagePolicy.cyrillicVerdict(text)
    }

    static func name(of code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        guard confidence >= 0.45 else { return nil }
        return LanguagePolicy.normalize(dominant.rawValue)
    }
}
