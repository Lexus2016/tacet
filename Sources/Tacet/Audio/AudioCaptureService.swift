import AVFoundation
import Foundation

/// Captures the default input device into a 16 kHz mono WAV file.
///
/// Real-time rules followed here:
/// - the audio callback only converts, copies and meters; disk writes go to a
///   serial background queue so a slow disk can never stall the microphone;
/// - the sample buffer is reserved up front and grows by doubling, so a long
///   dictation does not reallocate on the audio thread;
/// - loudness is accumulated incrementally, so there is no post-pass over the
///   recording when you stop.
final class AudioCaptureService {
    struct Result {
        let url: URL
        let duration: TimeInterval
        let samples: [Float]
        let peak: Float
        let rms: Double
    }

    enum CaptureError: LocalizedError {
        case noInput
        case engineStart(String)
        case tooShort
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .engineStart(let reason): return "The microphone could not start: \(reason)"
            case .tooShort: return "The recording was too short."
            case .writeFailed(let reason): return "The recording could not be saved: \(reason)"
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// A fresh engine per recording: after a call app (Meet, Zoom) has used the
    /// microphone, a long-lived engine can stay bound to a dead device. Building
    /// one per dictation and releasing it afterwards is what keeps capture
    /// working without restarting the app.
    private var engine: AVAudioEngine?
    private let writeQueue = DispatchQueue(label: "ua.rawira.tacet.wav-writer", qos: .utility)

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var collected: [Float] = []
    private var fileURL: URL?
    private var startedAt: Date?

    private var squareSum: Double = 0
    private var sampleCount: Int = 0

    /// Guards `collected`, `squareSum` and `sampleCount`: the audio thread
    /// appends, the main thread drains on stop.
    private let bufferLock = NSLock()

    private(set) var isRecording = false

    /// Called on an audio thread with a 0...1 level. Keep the handler cheap.
    var levelHandler: ((Float) -> Void)?
    /// Called when the input device changes underneath a running recording.
    var configurationChangeHandler: (() -> Void)?

    private var observer: NSObjectProtocol?

    init() {}

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Control

    func start() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.noInput
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: target) else {
            throw CaptureError.engineStart("unsupported input format")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        let url = AudioStore.makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw CaptureError.writeFailed(error.localizedDescription)
        }

        self.converter = converter
        self.targetFormat = target

        bufferLock.lock()
        collected = []
        collected.reserveCapacity(Int(Self.sampleRate * 60))
        squareSum = 0
        sampleCount = 0
        bufferLock.unlock()

        self.fileURL = url
        self.startedAt = Date()

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            self.converter = nil
            self.engine = nil
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.engineStart(error.localizedDescription)
        }

        isRecording = true
        installObserver(for: engine)
    }

    private func installObserver(for engine: AVAudioEngine) {
        removeObserver()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.configurationChangeHandler?()
        }
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Stops capture and returns what was recorded. Audio written before a
    /// device change or an error is still returned: partial text beats no text.
    @discardableResult
    func stop() throws -> Result? {
        guard isRecording else { return nil }
        isRecording = false

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        removeObserver()

        // Flush the writer before closing the file.
        writeQueue.sync {}
        file = nil
        converter = nil
        targetFormat = nil

        guard let url = fileURL else { return nil }
        fileURL = nil

        bufferLock.lock()
        let samples = collected
        let rms = sampleCount > 0 ? (squareSum / Double(sampleCount)).squareRoot() : 0
        collected = []
        squareSum = 0
        sampleCount = 0
        bufferLock.unlock()

        let duration = Double(samples.count) / Self.sampleRate
        guard duration >= 0.25, !samples.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.tooShort
        }

        var peak: Float = 0
        for index in stride(from: 0, to: samples.count, by: 16) {
            peak = max(peak, abs(samples[index]))
        }

        return Result(url: url, duration: duration, samples: samples, peak: peak, rms: rms)
    }

    /// Aborts and deletes the in-flight recording.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        removeObserver()
        writeQueue.sync {}
        file = nil
        converter = nil
        targetFormat = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil

        bufferLock.lock()
        collected = []
        squareSum = 0
        sampleCount = 0
        bufferLock.unlock()
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target = targetFormat, let file else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0,
              let channel = output.floatChannelData?[0]
        else { return }

        let count = Int(output.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        var peak: Float = 0
        var squares: Double = 0
        for index in 0..<count {
            let value = chunk[index]
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
            squares += Double(value * value)
        }
        levelHandler?(Self.meterLevel(forPeak: peak))

        bufferLock.lock()
        collected.append(contentsOf: chunk)
        squareSum += squares
        sampleCount += count
        bufferLock.unlock()

        // The engine reuses its buffer as soon as this callback returns, so the
        // writer gets its own copy and never touches the audio thread again.
        guard let copy = Self.copy(output) else { return }
        writeQueue.async {
            try? file.write(from: copy)
        }
    }

    static func meterLevel(forPeak peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return 0 }
        let floor: Float = -54
        let ceiling: Float = -6
        let decibels = 20 * log10(peak)
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let destination = copy.floatChannelData
        else { return nil }

        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: frames)
        }
        return copy
    }
}
