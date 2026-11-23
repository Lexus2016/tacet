import Foundation

/// Remembers the language of the last successful dictation per app.
///
/// The point is latency, not intelligence: when you dictate in Telegram in
/// Ukrainian and come back an hour later, the engine's detection is confirmed
/// instead of triggering the Ukrainian-vs-Russian second decode. It is a
/// fast-path confirmation — never a lock: a transcript whose script
/// contradicts the remembered language is still re-checked.
final class LanguageMemory {
    private let defaults = UserDefaults.standard
    private let key = "appLanguageMemory"
    private let limit = 200

    func language(for bundleID: String) -> String? {
        table()[bundleID]
    }

    func remember(_ language: String, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var table = table()
        table[bundleID] = language

        if table.count > limit {
            // Drop half arbitrarily; the exact set is not important.
            table = Dictionary(uniqueKeysWithValues: table.prefix(limit / 2).map { ($0.key, $0.value) })
        }

        defaults.set(table, forKey: key)
    }

    func forget(bundleID: String) {
        var table = table()
        table.removeValue(forKey: bundleID)
        defaults.set(table, forKey: key)
    }

    private func table() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
