# Tacet

Minimal, reliable dictation for macOS. One job: press a hotkey, speak, get text in the
focused field. Everything else — history, retry, cleanup — exists only to make that one
job survive failure.

GPL-3.0. Based on [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac); see `NOTICE`.

## What it is

- **Global hotkey → text anywhere.** Push-to-talk or toggle, inserts into the focused app.
- **A chain, not a single engine.** Primary, then fallbacks, then the recording stays on
  disk so nothing you said is lost.
- **Optional cleanup pass.** A second model fixes punctuation, casing and obvious ASR
  mistakes, with its own fallbacks and a strict guard: if the cleanup looks wrong, the raw
  transcript is used instead.
- **History with audio.** Search, copy, re-transcribe with another engine, retry a failed one.

## What it is not

No plugins, no workflows, no calendar automation, no cloud sync, no accounts, no telemetry,
no premium tier, no HTTP API, no widgets.

## Pipeline

```
hotkey ─▶ capture (16 kHz mono WAV written to disk immediately)
            │
            ▼
        ASR chain ── Groq whisper-large-v3-turbo
                  ── Parakeet TDT v3 (local, offline)
                  ── any OpenAI-compatible endpoint
            │  all failed → recording kept, entry marked "unrecovered", retry available
            ▼
        cleanup chain ── LLM (Groq / OpenAI-compatible)
                      ── raw transcript (fallback, always valid)
            │  guard: length ratio, refusal detection, timeout
            ▼
        insertion ── Accessibility ⌘V, clipboard always populated
            │
            ▼
        history (SQLite) + audio file
```

The design rule behind the whole thing: **the audio is the source of truth, the text is
derived.** Audio hits disk before any network call. A failed transcription never destroys
the recording.

## Requirements

- macOS 14 or later, Apple Silicon recommended
- Xcode 16+ (built and tested with Xcode 27)
- An API key for the cloud engine (Groq by default). Stored in Keychain, never in the repo.

## Build

```bash
./scripts/bootstrap.sh          # detects a signing identity, writes Configuration/Signing.local.xcconfig
./scripts/build.sh              # xcodegen + xcodebuild, output in .build/Build/Products/Debug/Tacet.app
open .build/Build/Products/Debug/Tacet.app
```

First launch: grant Microphone, then Accessibility (needed to paste into other apps).
Without Accessibility the transcript is placed on the clipboard and a notification says so.

## Configuration

Settings → Engines: paste the Groq key, choose the engine order.
Settings → Cleanup: enable the cleanup pass, pick the model, choose how long it may take.
Settings → History: retention for audio files.

Keys live in the login Keychain under `ua.rawira.tacet.apikey`. They are read at runtime
and never logged. For development you can also export `GROQ_API_KEY` in the environment;
the app prefers the Keychain value.

## Secrets policy

- `.gitignore` excludes `.env`, `*.local.xcconfig`, certificates and provisioning profiles.
- `scripts/secret-scan.sh` rejects commits containing key-shaped strings; it runs as a
  pre-commit hook (`.githooks/pre-commit`).
- The app never writes a key to disk outside Keychain and never includes one in a log line.

Enable the hook once per clone:

```bash
git config core.hooksPath .githooks
```

## Licence

GPL-3.0. The upstream copyright notice is preserved in `LICENSE`; the fork is named Tacet
and does not use TypeWhisper branding, per its trademark policy.
