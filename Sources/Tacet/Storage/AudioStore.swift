import AVFoundation
import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Tacet", isDirectory: true)
    }

    static var recordingsDirectory: URL {
        supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }
}

/// Audio is the source of truth: it is written to disk before any transcription
/// starts and removed only when the entry and its retention period are gone.
enum AudioStore {
    static func makeRecordingURL(at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let month = formatter.string(from: date)

        let directory = AppPaths.recordingsDirectory.appendingPathComponent(month, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).wav")
    }

    static func delete(path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Deletes recordings older than the retention window. Files still
    /// referenced by unrecovered entries are never touched.
    static func purge(olderThanDays days: Int, keeping paths: Set<String>) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: AppPaths.recordingsDirectory,
            includingPropertiesForKeys: keys
        ) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "wav" else { continue }
            if paths.contains(url.path) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func unrecoveredPaths() -> Set<String> {
        Set(HistoryStore.shared.entries(limit: 5_000)
            .filter { $0.status == .unrecovered }
            .compactMap(\.audioPath))
    }

    static func recentRecordings(modifiedAfter date: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: AppPaths.recordingsDirectory,
            includingPropertiesForKeys: keys
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "wav" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if (values?.contentModificationDate ?? .distantPast) >= date {
                result.append(url)
            }
        }
        return result
    }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }
}
