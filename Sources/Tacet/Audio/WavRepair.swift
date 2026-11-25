import Foundation

/// A WAV file whose writer was killed mid-recording still contains all the
/// audio; only the two size fields in the header are wrong (usually zero).
/// Repairing them turns a "lost" dictation into a recoverable one.
enum WavRepair {
    @discardableResult
    static func repairIfNeeded(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44,
              data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8),
              let riffSize = UInt32(exactly: data.count - 8), size(in: data, at: 4) != riffSize
        else { return false }

        var offset = 12
        var sawFormat = false
        while offset <= data.count - 8 {
            let id = data[offset..<(offset + 4)]
            let chunkSize = Int(size(in: data, at: offset + 4))
            let payloadStart = offset + 8
            let remaining = data.count - payloadStart
            if id == Data("data".utf8) {
                guard sawFormat, remaining > 0, chunkSize == 0 || chunkSize > remaining else { return false }
                var patched = data
                replaceSize(riffSize, in: &patched, at: 4)
                replaceSize(UInt32(remaining), in: &patched, at: offset + 4)
                return (try? patched.write(to: url, options: .atomic)) != nil
            }
            guard chunkSize <= remaining else { return false }
            if id == Data("fmt ".utf8), chunkSize >= 16 { sawFormat = true }
            offset = payloadStart + chunkSize + chunkSize % 2
        }
        return false
    }

    private static func size(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    private static func replaceSize(_ size: UInt32, in data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: size.littleEndian) { Data($0) })
    }
}
