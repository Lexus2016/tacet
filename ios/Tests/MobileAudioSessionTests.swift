import AVFoundation
import XCTest
@testable import Tacet

#if !targetEnvironment(simulator)
final class MobileAudioSessionTests: XCTestCase {
    func testActiveMicrophoneAllowsKeyboardHaptics() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("This device must already allow Tacet to use the microphone.")
        }
        let audio = SessionAudio()
        defer { audio.disarm() }
        try audio.arm()
        XCTAssertTrue(audio.isRunning)
        XCTAssertTrue(AVAudioSession.sharedInstance().allowHapticsAndSystemSoundsDuringRecording)
    }
}
#endif
