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

    static func load(url: URL) throws -> AudioClip {
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

    private static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
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
