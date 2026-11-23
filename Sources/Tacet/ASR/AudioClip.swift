import AVFoundation
import Foundation

/// 16 kHz mono audio, kept in memory for local engines and on disk for the
/// cloud ones and for retries.
struct AudioClip: Sendable {
    let url: URL
    let duration: TimeInterval
    let samples: [Float]

    static let sampleRate: Double = 16_000

    var isSilent: Bool {
        guard !samples.isEmpty else { return true }
        var sum: Double = 0
        for index in stride(from: 0, to: samples.count, by: 4) {
            let value = Double(samples[index])
            sum += value * value
        }
        let rms = (sum / Double(samples.count / 4 + 1)).squareRoot()
        return rms < 0.0016
    }

    var peak: Float {
        var maximum: Float = 0
        for index in stride(from: 0, to: samples.count, by: 16) {
            maximum = max(maximum, abs(samples[index]))
        }
        return maximum
    }

    static func load(url: URL) throws -> AudioClip {
        WavRepair.repairIfNeeded(url: url)

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw RecognitionError.failed("The recording is empty.")
        }
        try file.read(into: buffer)

        var monoSamples = extractMono(buffer)

        if abs(format.sampleRate - sampleRate) > 1, !monoSamples.isEmpty {
            monoSamples = resample(monoSamples, from: format.sampleRate, to: sampleRate)
        }

        return AudioClip(
            url: url,
            duration: Double(monoSamples.count) / sampleRate,
            samples: monoSamples
        )
    }

    private static func extractMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channels[0], count: frames))
            }
            var mixed = [Float](repeating: 0, count: frames)
            for channel in 0..<channelCount {
                let pointer = channels[channel]
                for index in 0..<frames {
                    mixed[index] += pointer[index] / Float(channelCount)
                }
            }
            return mixed
        }

        if let channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            var mixed = [Float](repeating: 0, count: frames)
            for channel in 0..<channelCount {
                let pointer = channels[channel]
                for index in 0..<frames {
                    mixed[index] += Float(pointer[index]) / 32_768.0 / Float(channelCount)
                }
            }
            return mixed
        }

        return []
    }

    /// Splits a long recording into pieces the cloud endpoints accept (25 MB is
    /// about thirteen minutes of 16 kHz mono PCM). Cuts near silence so a word
    /// is unlikely to be sliced in half.
    func chunked(seconds: TimeInterval) -> [AudioClip] {
        let chunkSamples = Int(seconds * Self.sampleRate)
        guard chunkSamples > 0, samples.count > chunkSamples else { return [self] }

        var result: [AudioClip] = []
        var start = 0

        while start < samples.count {
            let hardEnd = min(samples.count, start + chunkSamples)
            var end = hardEnd == samples.count ? hardEnd : quietCut(from: start, to: hardEnd)

            // Do not leave a sliver behind: merge a short tail into this piece.
            if samples.count - end < chunkSamples / 3 {
                end = samples.count
            }

            let slice = Array(samples[start..<end])
            guard !slice.isEmpty, let url = Self.writeTemporaryWav(slice) else {
                // Never return a silently truncated recording.
                for chunk in result { try? FileManager.default.removeItem(at: chunk.url) }
                return [self]
            }

            result.append(AudioClip(url: url,
                                    duration: Double(slice.count) / Self.sampleRate,
                                    samples: slice))
            start = end
        }

        return result.isEmpty ? [self] : result
    }

    /// The quietest 50 ms window in the last second before `hardEnd`.
    private func quietCut(from start: Int, to hardEnd: Int) -> Int {
        let window = Int(Self.sampleRate * 0.05)
        let searchWindow = max(Int(Self.sampleRate * 2),
                               min(Int(Self.sampleRate * 20), (hardEnd - start) / 4))
        let searchFrom = max(start + window, hardEnd - searchWindow)
        guard searchFrom < hardEnd - window else { return hardEnd }

        var bestStart = hardEnd - window
        var bestEnergy = Double.greatestFiniteMagnitude
        var index = searchFrom

        while index + window < hardEnd {
            var energy: Double = 0
            for sample in stride(from: index, to: index + window, by: 8) {
                let value = Double(samples[sample])
                energy += value * value
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestStart = index
            }
            index += window
        }

        return min(hardEnd, bestStart + window / 2)
    }

    private static func writeTemporaryWav(_ samples: [Float]) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tacet-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: 1,
                                             interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0]
            else { return nil }

            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }

        input.frameLength = AVAudioFrameCount(samples.count)
        if let destination = input.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: samples.count)
            }
        }

        let ratio = target / source
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return samples }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
