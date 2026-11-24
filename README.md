# Tacet

**Dictation for macOS from the menu bar.** Use a keyboard shortcut to speak into your editor, message, or document. Recognize speech on your Mac with Parakeet or connect a cloud provider. Tacet saves transcripts in History and restores the previous clipboard contents after automatic insertion.

[Українська](README.uk.md) · [Download Tacet](https://github.com/Lexus2016/tacet/releases/latest)

## Get started

1. Download the disk image for your Mac. Choose `arm64` for Apple Silicon or `x86_64` for Intel. Open it and move Tacet to Applications. macOS 14 or later is required.
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

## Build and updates

```bash
./scripts/bootstrap.sh
./scripts/build.sh
xcodebuild test -project Tacet.xcodeproj -scheme Tacet -destination 'platform=macOS'
```

Tacet uses a signed Sparkle update feed for each architecture. Open **About → Check for Updates…** to check manually. To publish a pushed revision, run `scripts/release.sh <major.minor.patch>`. It builds and notarizes both architectures, checks the update signatures, verifies uploaded assets in a draft, and then publishes the release.

Tacet is distributed under [GPL-3.0](LICENSE) and based on [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac). See [NOTICE](NOTICE).
