import AudioToolbox
import CoreAudio

struct OutputVolumeControl: Hashable {
    let device: AudioDeviceID
    let selector: AudioObjectPropertySelector
    let element: AudioObjectPropertyElement

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}

@MainActor
protocol OutputVolume {
    var defaultDevice: AudioDeviceID { get }
    func controls(for device: AudioDeviceID) -> [OutputVolumeControl]
    func read(_ control: OutputVolumeControl) -> Float32?
    func write(_ value: Float32, to control: OutputVolumeControl) -> Bool
    func observeDefaultDevice(_ handler: (() -> Void)?)
}

@MainActor
final class BackgroundAudioDucker {
    private struct Change {
        let control: OutputVolumeControl
        let original: Float32
        let applied: Float32
    }

    private let output: any OutputVolume
    private var device: AudioDeviceID?
    private var changes: [Change] = []

    init(output: any OutputVolume) {
        self.output = output
    }

    convenience init() {
        self.init(output: CoreAudioOutputVolume())
    }

    func begin() {
        guard device == nil else { return }
        output.observeDefaultDevice { [weak self] in
            guard let self, device != nil else { return }
            lowerCurrentOutput()
        }
        lowerCurrentOutput()
    }

    func end() {
        guard device != nil else { return }
        device = nil
        output.observeDefaultDevice(nil)
        restore()
    }

    private func lowerCurrentOutput() {
        let nextDevice = output.defaultDevice
        guard device != nextDevice else { return }
        restore()
        device = nextDevice

        for control in output.controls(for: nextDevice) {
            guard let original = output.read(control), original > 0 else { continue }
            let target = original * 0.25
            guard output.write(target, to: control) else { continue }
            let applied = output.read(control) ?? target
            guard applied != original else { continue }
            changes.append(Change(control: control, original: original, applied: applied))
        }
    }

    private func restore() {
        for change in changes where output.read(change.control) == change.applied {
            _ = output.write(change.original, to: change.control)
        }
        changes.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class CoreAudioOutputVolume: OutputVolume {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue.main
    private var listener: AudioObjectPropertyListenerBlock?

    private var defaultAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    var defaultDevice: AudioDeviceID {
        var address = defaultAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
    }

    func controls(for device: AudioDeviceID) -> [OutputVolumeControl] {
        guard device != kAudioObjectUnknown else { return [] }
        let mainVolume = OutputVolumeControl(device: device,
                                             selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                             element: kAudioObjectPropertyElementMain)
        let hardwareVolume = OutputVolumeControl(device: device, selector: kAudioDevicePropertyVolumeScalar,
                                                 element: kAudioObjectPropertyElementMain)
        if let main = [mainVolume, hardwareVolume].first(where: isWritable) { return [main] }

        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return [] }
        let streams = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channelCount = streams.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        return (0..<channelCount).map { channel in
            OutputVolumeControl(device: device, selector: kAudioDevicePropertyVolumeScalar, element: channel + 1)
        }.filter(isWritable)
    }

    func read(_ control: OutputVolumeControl) -> Float32? {
        var address = control.address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(control.device, &address, 0, nil, &size, &value) == noErr,
              (0...1).contains(value) else { return nil }
        return value
    }

    func write(_ value: Float32, to control: OutputVolumeControl) -> Bool {
        var address = control.address
        var value = value
        return AudioObjectSetPropertyData(control.device, &address, 0, nil,
                                          UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }

    func observeDefaultDevice(_ handler: (() -> Void)?) {
        var address = defaultAddress
        if let listener {
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
            self.listener = nil
        }
        guard let handler else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in handler() }
        }
        if AudioObjectAddPropertyListenerBlock(system, &address, queue, listener) == noErr {
            self.listener = listener
        }
    }

    private func isWritable(_ control: OutputVolumeControl) -> Bool {
        var address = control.address
        var writable = DarwinBoolean(false)
        return AudioObjectHasProperty(control.device, &address)
            && AudioObjectIsPropertySettable(control.device, &address, &writable) == noErr
            && writable.boolValue
    }
}
