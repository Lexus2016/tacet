# Tacet

**Minimal, reliable dictation for macOS.** One hotkey, speak, text appears. Everything
else exists to make that survive failure — a dead network, a retired model, a call app
holding the microphone, a process killed mid-recording.

[Українська](README.uk.md) · English

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)
[![Swift 5](https://img.shields.io/badge/Swift-5-orange.svg)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/Lexus2016/tacet)](https://github.com/Lexus2016/tacet/releases/latest)

## Why Tacet

TypeWhisper proved that on-device and cloud dictation can feel instant; it also grew to
300k lines around that one button. Tacet is the same idea rebuilt small: no plugins, no
workflows, no accounts, no telemetry. One hotkey, a fallback chain, a history you can
trust.

## Features

- **Global hotkey** — right Command by default, or any recorded combination, including a
  single modifier. Push-to-talk or toggle.
- **Never loses audio** — the WAV is written before any network call, repaired if the
  process died mid-recording, and transcribed automatically on the next launch.
- **Three ASR paths** — Groq `whisper-large-v3-turbo`, Parakeet TDT v3 on-device, any
  OpenAI-compatible endpoint. The first plausible transcript wins.
- **Language per dictation** — Ukrainian, Russian, English and more, detected separately
  for every recording; a script check and a conditional second decode resolve uk/ru
  ambiguity, and the language you last used in an app is remembered.
- **Optional voice language check** — Gemini Decision (OpenRouter) listens to the clip
  itself, which catches Ukrainian speech decoded as Russian.
- **Output language** — dictate in any language, insert in another; the transcript is
  translated after cleanup, and the original is kept if translation fails.
- **Edit selected text** — with text selected, the dictation rewrites, translates,
  shortens or deletes it instead of inserting after it.
- **Cleanup with a guard** — an LLM fixes punctuation and obvious errors; anything
  suspicious (translation, dropped content, wrong language, timeout) is discarded and the
  raw transcript is used.
- **History** — search, copy, retry a failed recording, re-read its audio.
- **Four indicator styles** — Tacet island, Notch, Overlay, Minimal; top or bottom.
- **Seven interface languages** — English, Ukrainian, French, Spanish, German, Portuguese,
  Simplified Chinese, Hindi. Anything untranslated falls back to English.
- **Signed Sparkle updates** — per-architecture feeds, notarized builds.

## Languages

| Interface | Codes |

| English | `en` |
| Ukrainian | `uk` |
| French | `fr` |
| Spanish | `es` |
| German | `de` |
| Portuguese | `pt` |
| Simplified Chinese | `zh-Hans` |
| Hindi | `hi` |

Speech recognition covers far more: Groq and OpenAI accept roughly a hundred languages;
Parakeet covers 25 European ones, including Ukrainian, Russian and English.

## Files

```
Sources/Tacet/
  App/        controller, windows, updater, CLI diagnostics
  Audio/      capture, WAV repair, sound cues
  ASR/        recognizers, language policy, pipeline, chunking
  Cleanup/    cleanup, translation, selection editor
  Providers/  provider catalogue, model lists, connection tests
  Input/      hotkey, text insertion, selection reader
  Storage/    settings, history, keychain
  UI/         settings, history, indicator styles, design system
  Resources/  Info.plist, assets, seven .lproj tables
scripts/      build, icon, DMG background, release
```

## Providers and models

Transcription: **Groq** (default `whisper-lg-v3-turbo`), **Parakeet** (local, no key),
**OpenAI-compatible** (custom base URL). Cleanup and translation: Groq, OpenAI,
OpenRouter, Cerebras, Ollama, Ollama Cloud — each with its own key, model, a searchable
model browser and a real connection test.

## Install

Download the DMG from [Releases](https://github.com/Lexus2016/tacet/releases/latest) —
`arm64` for Apple Silicon, `x86_64` for Intel. Open it and drag **Tacet** to
**Applications**.

The app is signed with a Developer ID and notarized; the disk image and the app inside are
both accepted by Gatekeeper.

## First launch

1. Settings → Engines: paste a Groq key (or download the Parakeet model for offline use)
   and press **Test connection**.
2. Grant **Microphone**.
3. Grant **Accessibility** — needed to paste into other apps. Without it the transcript is
   copied to the clipboard instead.

## Hotkey and Accessibility

The default is a single **right Command**: hold it while you speak, release to transcribe.
Any combination can be recorded in Settings → General; modifier-only keys always behave as
push-to-talk. If a combination is owned by another app, Tacet moves to a free one and says
so.

While the engine starts, the indicator shows **Preparing microphone…**; releasing the key
during that moment cancels the start instead of recording a fragment.

## Interface language

Settings → Behaviour → Interface language. macOS applies it after a relaunch; a restart
button sits next to the picker. Missing translations fall back to English.

## Updates

Tacet checks the release feed once a day and offers the new version in a standard update
window; **Check for Updates…** runs it on demand. Updates are signed with an EdDSA key, so
a tampered build is refused. Apple Silicon and Intel builds read separate feeds.
Publishing a release:

```bash
scripts/release.sh 0.2.12
```

The script builds both architectures, signs, notarizes and staples the app and the disk
image, generates both appcasts, pushes the tag and publishes the GitHub release.

## Reliability

- **Digital silence means a blocked microphone**, not an empty room: the app says so and
  opens the privacy pane instead of reporting "no speech".
- **A fresh audio engine per dictation** — a call app that held or switched the input can
  no longer leave capture dead until restart.
- **WAV header repair** — a recording killed mid-write is readable again and recovered on
  the next launch.
- **Long dictations** — audio past ten minutes is split near silence and joined, so the
  25 MB cloud limit never truncates a thought.
- **Partial results** — if one part of a long recording fails, the rest is kept and the
  failure is reported.

## Build

```bash
./scripts/bootstrap.sh      # signing identity → Configuration/Signing.local.xcconfig
./scripts/build.sh          # xcodegen + xcodebuild → .build/Build/Products/Debug/Tacet.app
xcodebuild test -project Tacet.xcodeproj -scheme Tacet -destination 'platform=macOS'
```

## Licence

GPL-3.0. Based on [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac); see
`NOTICE`. The fork uses its own name and icon, as the upstream trademark policy requires.
