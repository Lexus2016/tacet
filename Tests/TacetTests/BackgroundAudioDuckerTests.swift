import CoreAudio
import XCTest
@testable import Tacet

@MainActor
final class BackgroundAudioDuckerTests: XCTestCase {
    func testRestoresTheOriginalLevelAfterRecording() {
        let output = TestOutput()
        let control = output.addControl(on: 1, volume: 0.8)
        let ducker = BackgroundAudioDucker(output: output)

        ducker.begin()
        XCTAssertEqual(output.read(control), 0.2)
        ducker.begin()
        XCTAssertEqual(output.read(control), 0.2)
        ducker.end()
        XCTAssertEqual(output.read(control), 0.8)
        XCTAssertNil(output.onRouteChange)
    }

    func testKeepsManualVolumeChangesAndLeavesMutedChannelsAlone() {
        let output = TestOutput()
        let left = output.addControl(on: 1, element: 1, volume: 0.8)
        let right = output.addControl(on: 1, element: 2, volume: 0.4)
        let silent = output.addControl(on: 1, element: 3, volume: 0)
        let ducker = BackgroundAudioDucker(output: output)

        ducker.begin()
        XCTAssertEqual(output.read(right), 0.1)
        XCTAssertFalse(output.writes.contains(silent))
        output.volumes[left] = 0.6
        ducker.end()
        XCTAssertEqual(output.read(left), 0.6)
        XCTAssertEqual(output.read(right), 0.4)
    }

    func testRestoresPreviousDeviceAndFollowsRouteChanges() {
        let output = TestOutput()
        let speakers = output.addControl(on: 1, volume: 0.8)
        let headphones = output.addControl(on: 2, volume: 0.4)
        let ducker = BackgroundAudioDucker(output: output)

        ducker.begin()
        output.defaultDevice = 3
        XCTAssertEqual(output.read(speakers), 0.8)
        output.defaultDevice = 2
        XCTAssertEqual(output.read(headphones), 0.1)
        ducker.end()
        XCTAssertEqual(output.read(headphones), 0.4)
        output.defaultDevice = 1
        XCTAssertEqual(output.read(speakers), 0.8)
    }
}

@MainActor
private final class TestOutput: OutputVolume {
    var defaultDevice: AudioDeviceID = 1 {
        didSet { onRouteChange?() }
    }
    var volumes: [OutputVolumeControl: Float32] = [:]
    var writes: [OutputVolumeControl] = []
    var onRouteChange: (() -> Void)?

    func addControl(on device: AudioDeviceID, element: UInt32 = 0, volume: Float32) -> OutputVolumeControl {
        let control = OutputVolumeControl(device: device, selector: kAudioDevicePropertyVolumeScalar, element: element)
        volumes[control] = volume
        return control
    }

    func controls(for device: AudioDeviceID) -> [OutputVolumeControl] {
        volumes.keys.filter { $0.device == device }
    }

    func read(_ control: OutputVolumeControl) -> Float32? {
        volumes[control]
    }

    func write(_ value: Float32, to control: OutputVolumeControl) -> Bool {
        writes.append(control)
        volumes[control] = value
        return true
    }

    func observeDefaultDevice(_ handler: (() -> Void)?) {
        onRouteChange = handler
    }
}
