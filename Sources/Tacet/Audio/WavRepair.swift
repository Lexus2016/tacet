import Foundation

/// A WAV file whose writer was killed mid-recording still contains all the
/// audio; only the two size fields in the header are wrong (usually zero).
/// Repairing them turns a "lost" dictation into a recoverable one.
enum WavRepair {
    @discardableResult
    static func repairIfNeeded(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return false }

        let dataMarker = Data("data".utf8)
        guard let markerRange = data.range(of: dataMarker),
              markerRange.lowerBound >= 0,
              markerRange.upperBound + 4 <= data.count
        else { return false }

        let sizeOffset = markerRange.upperBound
        let payloadSize = UInt32(data.count - (sizeOffset + 4))
        let riffSize = UInt32(data.count - 8)

        let currentDataSize = data[sizeOffset..<(sizeOffset + 4)].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let currentRiffSize = data[4..<8].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }

        guard currentDataSize != payloadSize || currentRiffSize != riffSize else {
            return false
        }

        var patched = data
        patched.replaceSubrange(4..<8, with: withUnsafeBytes(of: riffSize.littleEndian) { Data($0) })
        patched.replaceSubrange(sizeOffset..<(sizeOffset + 4),
                                with: withUnsafeBytes(of: payloadSize.littleEndian) { Data($0) })

        return (try? patched.write(to: url, options: .atomic)) != nil
    }
}
