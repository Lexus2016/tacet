# Tacet for iPhone

The iPhone app is a parallel track, not a port. Two hard constraints shape it:

1. **iOS has no API to type into another app.** The only way to dictate into
   Messages, Mail, Slack or any other app is a custom keyboard extension. A
   standalone app can record, transcribe and copy — nothing more.
2. **Microphone permission is granted to the containing app, not the
   extension.** The keyboard cannot show the system prompt for the first time;
   the app must request it once before the keyboard can record.

So the product is two surfaces over one core:

- **Tacet** (app): record, transcribe, history, share/copy, settings.
- **Tacet Keyboard** (extension): a mic button, the same engine chain, text
  inserted straight into the focused field. Needs "Allow Full Access" for the
  network and the microphone.

## What is shared with the Mac

The folders below are platform-neutral today and are the intended contents of a
`TacetCore` package when the iOS target starts:

| Folder | Depends on | Notes |
|---|---|---|
| `ASR/` | Foundation, AVFoundation, FluidAudio | `AudioClip`, engine protocol, Groq/OpenAI adapters, Parakeet, language policy, pipeline |
| `Cleanup/` | Foundation | LLM cleanup and its trust guard |
| `Storage/Keychain.swift` | Security | identical on iOS |
| `Storage/HistoryStore.swift` | SQLite3 | needs the database URL injected instead of `AppPaths` |
| `Storage/AppSettings.swift` | SwiftUI, UserDefaults | portable as is |

Mac-only: `AudioCaptureService` (AVAudioEngine tap + WAV), `HotkeyManager`
(Carbon), `TextInserter` (CGEvent), `AudioStore` (Application Support paths),
all SwiftUI views.

FluidAudio supports iOS 17, so the Parakeet fallback runs on the phone itself.
The engine order is the same: Groq → Parakeet (on-device) → OpenAI-compatible.

## Audio session

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth])
try session.setActive(true, options: .notifyOthersOnDeactivation)
```

`.measurement` disables the system's own processing, which is what the engines
were trained on. Recording stops the session on completion: iOS suspends audio
sessions that stay active without reason.

## Keyboard extension specifics

- `Info.plist`: `NSExtension > NSExtensionAttributes > RequestsOpenAccess = YES`.
- First run: open the containing app, grant Microphone there, then enable the
  keyboard in Settings → General → Keyboard → Keyboards.
- The extension gets roughly 50 MB; Parakeet's 600 MB model cannot be loaded
  there. The keyboard should use Groq, and the app can offer the on-device
  engine for longer dictations.
- Insert the result with `textDocumentProxy.insertText(_:)`; never replace the
  whole document.

## Optional Mac bridge

When the phone and the Mac are on the same network, the Mac can expose
`POST /v1/transcribe` bound to the LAN with a per-pairing token, so the phone
uses the Mac's Parakeet model and never uploads audio. This is a nice-to-have:
Groq works anywhere and is the primary path, matching the Mac app.

## Distribution

The Mac build uses a Developer ID certificate. iOS needs an Apple Development
certificate plus a provisioning profile for a physical device, or a simulator
build for development. The app must run on a device to test the keyboard —
simulator keyboards cannot request the microphone.
