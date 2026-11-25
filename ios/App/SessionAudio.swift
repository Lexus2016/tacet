import AVFoundation
import Foundation

/// Holds the input open only for an explicitly armed session.
/// Тримає мікрофон відкритим лише під час явно ввімкненої сесії.
final class SessionAudio {
    private let engine = AVAudioEngine()
    private let capture = Capture()
    private var hasTap = false
    private var sampleRate: Double = 0

    var isRunning: Bool { engine.isRunning }

    func arm() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw MobileDictationError.noInput }
            sampleRate = format.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [capture] buffer, _ in
                capture.append(buffer)
            }
            hasTap = true
            try engine.start()
        } catch {
            disarm()
            throw error
        }
    }

    func begin() { capture.begin(limit: Int(sampleRate * 60)) }
    func finish() -> Recording { Recording(samples: capture.finish(), rate: sampleRate) }
    func cancel() { capture.cancel() }

    func disarm() {
        capture.cancel()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    struct Recording: Sendable {
        let samples: [Float]
        let rate: Double

        func makeClip() throws -> AudioClip {
            guard rate > 0, Double(samples.count) / rate >= 0.25,
                  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let data = buffer.floatChannelData else { throw MobileDictationError.tooShort }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { sampleBuffer in
                if let source = sampleBuffer.baseAddress { data[0].update(from: source, count: samples.count) }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
            do {
                try AVAudioFile(forWriting: url, settings: settings).write(from: buffer)
                let clip = try AudioClip.load(url: url)
                guard !clip.isSilent else { throw RecognitionError.noSpeech }
                return clip
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var limit = 0
        private var samples: [Float] = []

        func begin(limit: Int) {
            var fresh: [Float] = []
            fresh.reserveCapacity(limit)
            lock.withLock {
                self.limit = limit
                samples = fresh
            }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData else { return }
            lock.withLock {
                let count = min(Int(buffer.frameLength), limit - samples.count)
                guard count > 0 else { return }
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            }
        }

        func finish() -> [Float] {
            lock.withLock {
                let captured = samples
                samples = []
                limit = 0
                return captured
            }
        }

        func cancel() { _ = finish() }
    }
}
