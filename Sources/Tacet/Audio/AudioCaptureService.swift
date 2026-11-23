import AVFoundation
import Foundation

/// Captures the default input device into a 16 kHz mono WAV file.
/// The file is opened before the engine starts, so a crash mid-dictation leaves
/// a playable recording behind.
final class AudioCaptureService {
    struct Result {
        let url: URL
        let duration: TimeInterval
        let samples: [Float]
        let peak: Float
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

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var collected: [Float] = []
    private var fileURL: URL?
    private var startedAt: Date?

    private(set) var isRecording = false

    /// Called on an audio thread with a 0...1 level. Keep the handler cheap.
    var levelHandler: ((Float) -> Void)?
    /// Called when the input device changes underneath a running recording.
    var configurationChangeHandler: (() -> Void)?

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.configurationChangeHandler?()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Control

    func start() throws {
        guard !isRecording else { return }

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
        self.collected = []
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
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.engineStart(error.localizedDescription)
        }

        isRecording = true
    }

    /// Stops capture and returns what was recorded. Audio written before a
    /// device change or an error is still returned: partial text beats no text.
    @discardableResult
    func stop() throws -> Result? {
        guard isRecording else { return nil }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        converter = nil
        targetFormat = nil

        guard let url = fileURL else { return nil }
        fileURL = nil

        let duration = Double(collected.count) / Self.sampleRate
        guard duration >= 0.25, !collected.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.tooShort
        }

        var peak: Float = 0
        for index in stride(from: 0, to: collected.count, by: 16) {
            peak = max(peak, abs(collected[index]))
        }

        return Result(url: url, duration: duration, samples: collected, peak: peak)
    }

    /// Aborts and deletes the in-flight recording.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        converter = nil
        targetFormat = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        collected = []
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

        guard status != .error, output.frameLength > 0 else { return }

        // Keep the samples even if the WAV write fails: the local engine reads
        // them from memory, and a half-written file only costs the cloud path.
        if let channel = output.floatChannelData?[0] {
            let count = Int(output.frameLength)
            collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))

            var peak: Float = 0
            for index in stride(from: 0, to: count, by: 8) {
                peak = max(peak, abs(channel[index]))
            }
            levelHandler?(min(1, peak * 1.6))
        }

        try? file.write(from: output)
    }
}
