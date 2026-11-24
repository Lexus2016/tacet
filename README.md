<p align="center">
  <img src="Sources/Tacet/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" height="96" alt="Tacet app icon">
</p>

<h1 align="center">Tacet</h1>

<p align="center"><strong>Dictation for macOS from the menu bar</strong></p>

<p align="center">
  <a href="https://lexus2016.github.io/tacet/?lang=en"><strong>Tacet website</strong></a>
  · <a href="https://github.com/Lexus2016/tacet/releases/latest">Download Tacet</a>
</p>

English · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md)

Use a keyboard shortcut to dictate into a document, editor, or message. Recognize speech on your Mac with Parakeet or connect a cloud provider. Tacet saves transcripts in History and restores your clipboard after automatic insertion.

Speak one of the supported languages and let Tacet detect it for each dictation. Choose an output language and connect a text provider to insert a translation directly into the active app.

## From voice to a sentence

See the recording indicator, automatic language detection and an example of optional translation.

[![Illustrative walkthrough using Tacet’s actual recording and transcription indicators.](docs/media/tacet-demo.gif)](https://lexus2016.github.io/tacet/?lang=en#demo)

| Settings | History |
| --- | --- |
| ![General settings for shortcuts, permissions and output.](docs/media/settings.webp) | ![History with sample transcripts and the original recording controls.](docs/media/history.webp) |

## Install on macOS 14 or later

1. On the [latest release page](https://github.com/Lexus2016/tacet/releases/latest), download the Apple-notarized disk image ending in `arm64.dmg` for Apple Silicon or `x86_64.dmg` for Intel. Open it and drag Tacet to Applications.
2. In **Settings → Providers**, download Parakeet for on-device recognition or configure a cloud provider. Check **Engines** to see the order in which Tacet tries them.
3. In **Settings → General**, grant microphone and Accessibility access. Hold the right Command key to dictate. You can record a different shortcut or switch to start-and-stop mode.
4. Place the cursor in the editor and speak. When automatic insertion is off, Tacet copies the result for you to paste. If the original editor is unavailable, find the transcript in **History**.

## Dictation and editing

- **Recognition.** Choose a language or let Tacet detect it for each dictation. Set the recognition order to fall back to another engine when one fails.
- **Cleanup and translation.** Pick a configured chat provider to fix punctuation or translate the result. The original transcript remains available in History.
- **Edit a selection.** Select text and dictate a change. Tacet checks the original editor and selection before replacing it through automatic insertion. If it cannot verify the selection, it saves a result or the instruction in History.
- **Recover a recording.** History can play saved audio and retry a failed recording. Configure audio retention under **General**.
- **Indicator.** Choose Classic, Glass, or Light and place the indicator at the top or bottom of the screen.

On-device recognition runs on your Mac after downloading the model. Audio goes to configured cloud services when you use cloud recognition or the optional voice-language check. Cleanup, translation, and selection editing send text to the configured chat provider. Provider credentials live in the macOS Keychain.

## Updates

Tacet checks for updates once a day. Starting with 0.2.26, it defaults to installing updates in the background and relaunches after dictation and transcription finish. Existing update preferences are respected. If automatic installation was off in your previous version, open **About → Check for Updates…** to confirm the upgrade.

## Build from source

```bash
./scripts/bootstrap.sh
./scripts/build.sh
xcodebuild test -project Tacet.xcodeproj -scheme Tacet -destination 'platform=macOS'
```

To publish a pushed revision, run `scripts/release.sh <major.minor.patch>` on a Mac configured for release signing. It builds and notarizes both architectures, verifies the signed Sparkle feeds and draft files, and publishes the release.

Tacet is distributed under [GPL-3.0](LICENSE) and based on [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac). See [NOTICE](NOTICE).
