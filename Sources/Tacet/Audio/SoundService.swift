import AppKit
import AVFoundation

enum SoundCue: String, CaseIterable, Identifiable {
    case start
    case success
    case error

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .start: return "recording_start"
        case .success: return "transcription_success"
        case .error: return "error"
        }
    }

    var systemName: String {
        switch self {
        case .start: return "Tink"
        case .success: return "Pop"
        case .error: return "Basso"
        }
    }
}

/// Short cues. The bundled files are the ones TypeWhisper uses; the system
/// option is there for people who prefer the macOS sounds.
final class SoundService {
    static let shared = SoundService()

    private var players: [String: AVAudioPlayer] = [:]

    func play(_ cue: SoundCue, style: String) {
        guard style != "off" else { return }

        if style == "system" {
            NSSound(named: cue.systemName)?.play()
            return
        }

        guard let url = Bundle.main.url(forResource: cue.fileName, withExtension: "wav") else { return }

        do {
            if players[cue.rawValue] == nil {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[cue.rawValue] = player
            }
            guard let player = players[cue.rawValue] else { return }
            player.currentTime = 0
            player.play()
        } catch {
            players[cue.rawValue] = nil
        }
    }
}
