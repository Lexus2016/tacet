import Foundation
import SQLite3

struct HistoryEntry: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        /// Transcribed and delivered (or copied).
        case ok
        /// Every engine failed; the audio is kept and the entry can be retried.
        case unrecovered
    }

    let id: String
    var createdAt: Date
    var text: String
    var rawText: String?
    var engine: String?
    var language: String?
    var duration: Double
    var latency: Double
    var appName: String?
    var audioPath: String?
    var status: Status
    var inserted: Bool
    var cleanupEngine: String?
    /// Why the attempt failed, when it did. Shown in History.
    var error: String?

    var audioURL: URL? {
        guard let audioPath, !audioPath.isEmpty else { return nil }
        return URL(fileURLWithPath: audioPath)
    }
}

/// Small synchronous SQLite wrapper. One connection, serial queue, WAL.
/// History is small enough that a plain table with LIKE is faster than FTS.
final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ua.rawira.tacet.history")

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let url = AppPaths.supportDirectory.appendingPathComponent("history.sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        queue.sync {
            guard sqlite3_open(url.path, &db) == SQLITE_OK else {
                NSLog("Tacet: cannot open history database at \(url.path)")
                db = nil
                return
            }
            sqlite3_busy_timeout(db, 3000)
            exec("PRAGMA journal_mode=WAL;")
            exec("PRAGMA synchronous=NORMAL;")
            exec("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                text TEXT NOT NULL,
                raw_text TEXT,
                engine TEXT,
                language TEXT,
                duration REAL NOT NULL DEFAULT 0,
                latency REAL NOT NULL DEFAULT 0,
                app_name TEXT,
                audio_path TEXT,
                status TEXT NOT NULL DEFAULT 'ok',
                inserted INTEGER NOT NULL DEFAULT 0,
                cleanup_engine TEXT
            );
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created_at DESC);")
            if !columnExists("error") {
                exec("ALTER TABLE entries ADD COLUMN error TEXT;")
            }
        }
    }

    private func columnExists(_ name: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(entries);") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1), String(cString: cString) == name {
                return true
            }
        }
        return false
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Writes

    @discardableResult
    func insert(text: String,
                rawText: String?,
                engine: String?,
                language: String?,
                duration: Double,
                latency: Double,
                appName: String?,
                audioPath: String?,
                status: HistoryEntry.Status,
                cleanupEngine: String?,
                error: String? = nil) -> HistoryEntry {
        let entry = HistoryEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            text: text,
            rawText: rawText,
            engine: engine,
            language: language,
            duration: duration,
            latency: latency,
            appName: appName,
            audioPath: audioPath,
            status: status,
            inserted: false,
            cleanupEngine: cleanupEngine,
            error: error
        )

        queue.sync {
            let sql = """
            INSERT INTO entries
            (id, created_at, text, raw_text, engine, language, duration, latency, app_name, audio_path, status, inserted, cleanup_engine, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }

            bind(stmt, 1, entry.id)
            sqlite3_bind_double(stmt, 2, entry.createdAt.timeIntervalSince1970)
            bind(stmt, 3, entry.text)
            bind(stmt, 4, entry.rawText)
            bind(stmt, 5, entry.engine)
            bind(stmt, 6, entry.language)
            sqlite3_bind_double(stmt, 7, entry.duration)
            sqlite3_bind_double(stmt, 8, entry.latency)
            bind(stmt, 9, entry.appName)
            bind(stmt, 10, entry.audioPath)
            bind(stmt, 11, entry.status.rawValue)
            sqlite3_bind_int(stmt, 12, entry.inserted ? 1 : 0)
            bind(stmt, 13, entry.cleanupEngine)
            bind(stmt, 14, entry.error)
            sqlite3_step(stmt)
        }

        return entry
    }

    func setDuration(id: String, duration: Double) {
        queue.sync {
            guard let stmt = prepare("UPDATE entries SET duration = ? WHERE id = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, duration)
            bind(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func markInserted(id: String) {        queue.sync {
            guard let stmt = prepare("UPDATE entries SET inserted = 1 WHERE id = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    func update(id: String,
                text: String,
                rawText: String?,
                engine: String?,
                language: String?,
                latency: Double,
                status: HistoryEntry.Status,
                cleanupEngine: String?,
                error: String? = nil) {
        queue.sync {
            let sql = """
            UPDATE entries SET text = ?, raw_text = ?, engine = ?, language = ?,
            latency = ?, status = ?, cleanup_engine = ?, error = ? WHERE id = ?;
            """
            guard let stmt = prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, text)
            bind(stmt, 2, rawText)
            bind(stmt, 3, engine)
            bind(stmt, 4, language)
            sqlite3_bind_double(stmt, 5, latency)
            bind(stmt, 6, status.rawValue)
            bind(stmt, 7, cleanupEngine)
            bind(stmt, 8, error)
            bind(stmt, 9, id)
            sqlite3_step(stmt)
        }
    }

    func delete(id: String) -> String? {
        queue.sync {
            var path: String?
            if let stmt = prepare("SELECT audio_path FROM entries WHERE id = ?;") {
                bind(stmt, 1, id)
                if sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) {
                    path = String(cString: cString)
                }
                sqlite3_finalize(stmt)
            }
            if let stmt = prepare("DELETE FROM entries WHERE id = ?;") {
                bind(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            return path
        }
    }

    // MARK: Reads

    func entries(limit: Int = 500, query: String = "") -> [HistoryEntry] {
        queue.sync {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql: String
            if trimmed.isEmpty {
                sql = "SELECT * FROM entries ORDER BY created_at DESC LIMIT ?;"
            } else {
                sql = "SELECT * FROM entries WHERE text LIKE ? OR raw_text LIKE ? ORDER BY created_at DESC LIMIT ?;"
            }
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }

            if trimmed.isEmpty {
                sqlite3_bind_int(stmt, 1, Int32(limit))
            } else {
                let pattern = "%\(trimmed)%"
                bind(stmt, 1, pattern)
                bind(stmt, 2, pattern)
                sqlite3_bind_int(stmt, 3, Int32(limit))
            }

            var result: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = readRow(stmt) { result.append(entry) }
            }
            return result
        }
    }

    func entry(id: String) -> HistoryEntry? {
        queue.sync {
            guard let stmt = prepare("SELECT * FROM entries WHERE id = ?;") else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readRow(stmt)
        }
    }

    func last() -> HistoryEntry? {
        queue.sync {
            guard let stmt = prepare("SELECT * FROM entries ORDER BY created_at DESC LIMIT 1;") else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readRow(stmt)
        }
    }

    func count() -> Int {
        queue.sync {
            guard let stmt = prepare("SELECT COUNT(*) FROM entries;") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func knownAudioPaths() -> Set<String> {
        queue.sync {
            guard let stmt = prepare("SELECT audio_path FROM entries WHERE audio_path IS NOT NULL;") else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            var paths = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    paths.insert(String(cString: cString))
                }
            }
            return paths
        }
    }

    // MARK: Plumbing

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Tacet: SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func readRow(_ stmt: OpaquePointer) -> HistoryEntry? {
        guard let id = column(stmt, 0), let text = column(stmt, 2) else { return nil }
        return HistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            text: text,
            rawText: column(stmt, 3),
            engine: column(stmt, 4),
            language: column(stmt, 5),
            duration: sqlite3_column_double(stmt, 6),
            latency: sqlite3_column_double(stmt, 7),
            appName: column(stmt, 8),
            audioPath: column(stmt, 9),
            status: HistoryEntry.Status(rawValue: column(stmt, 10) ?? "ok") ?? .ok,
            inserted: sqlite3_column_int(stmt, 11) != 0,
            cleanupEngine: column(stmt, 12),
            error: column(stmt, 13)
        )
    }
}
