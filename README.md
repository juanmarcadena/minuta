# Minuta

A small macOS menu-bar app that writes a transcript of every call, on your Mac.

When Zoom, Teams, Google Meet (in Safari or Chrome), Slack, WhatsApp or FaceTime opens the microphone, Minuta starts recording. It captures your microphone and only that app's sound, as two separate tracks. When the call ends it transcribes both sides with Whisper on the Neural Engine and saves one Markdown file per meeting, named after the matching calendar event. Then it deletes the audio.

There is no bot in the call and no account, and nothing is uploaded.

> **Consent.** Nobody on the call is told that Minuta is running. Recording laws differ by country and state; tell people you are transcribing.

## What you get

```markdown
---
date: 2026-10-16T15:00:00-06:00
duration: 47m
app: Zoom
title: Weekly sync
languages: [en, es]
attendees: [Dana Pérez, Sam Lee]
meeting_link: https://zoom.us/j/123
---

# Weekly sync — 16 Oct 2026, 15:00

**[00:00:04] Me:** Hola a todos, let's start with the numbers.

**[00:00:11] Them 1:** Sure. Conversion went up three points this week.
```

- **Me / Them** come from separate tracks (your mic and the call app), so your side is never confused with theirs. The other side is split into Them 1, Them 2, … by on-device speaker diarization.
- **Language is detected per short chunk.** A call that switches between Spanish and English keeps each part in its own language; Whisper otherwise tends to translate the minority language.
- **Calendar names and links.** The event on now that has a link for the call's app gives the title, attendees and link. Attendee names also go to Whisper as vocabulary so they are spelled right.
- **A Transcripts window** (⌘T from the menu) lists every call by day, with search across all of them (ignoring case and accents) and Me/Them in different colors.

## How it works

| Piece | Built with |
|---|---|
| Menu bar app, settings, viewer | SwiftUI (`MenuBarExtra`, `NavigationSplitView`, `.searchable`) |
| Knowing a call started | Core Audio process objects: which app has its mic input running |
| The other side's audio | Core Audio process tap (`CATapDescription`) on the call app's processes, in a private aggregate device |
| Your side | `AVAudioEngine` |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) `large-v3-turbo` (Core ML, Neural Engine) |
| Speaker diarization | SpeakerKit (pyannote) from the same package |
| Calendar | EventKit, read-only |
| Start at login | `SMAppService` |

The pure logic lives in `MinutaCore` and is unit tested: the detection state machine, merging the two tracks, chunk planning, phantom-phrase filtering, speaker assignment, and the Markdown writer and parser.

Automatic recording starts the moment a call app opens the mic, so the first words are kept. It is thrown away if the mic closes again within 20 seconds (dictation, a voice note). It stops 30 seconds after the call ends. Recordings under a minute with no calendar event are dropped. If the audio device changes mid-call (AirPods in or out), both tracks follow the new device, and the gap is filled with silence so timestamps stay true.

### Why WhisperKit

Before building, Apple's `SpeechTranscriber`, whisper.cpp, WhisperKit and Parakeet v3 were compared on meetings in Spanish, English, Spanglish and with a mid-call language switch, using synthetic voices degraded to sound like a call.

- **WhisperKit with a vocabulary prompt** was best on Spanglish (about 9% word error rate against 31% for Apple's transcriber) and on product and people names.
- **Apple's transcriber** was fastest, but it has no language detection or diarization, and its custom vocabulary had no effect.
- **Parakeet** was 10× faster and excellent on pure Spanish, but weaker on Spanglish.

## Requirements

- macOS 26 or later, Apple silicon. Tested on an M2 with 8 GB.
- Xcode 26 or later.
- About 1 GB of disk for the models, downloaded on first use to `~/Library/Application Support/Minuta/Models`.

## Build

1. Create `Config/Local.xcconfig` with your Apple team and a bundle ID of your own. A free Apple ID in Xcode → Settings → Accounts is enough:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.yourname.minuta
   ```

2. Build Release. Debug builds of WhisperKit are much slower and gave empty transcripts in testing:

   ```bash
   xcodebuild -project Minuta.xcodeproj -scheme Minuta -configuration Release -derivedDataPath build -allowProvisioningUpdates build
   ```

3. Copy it to Applications and open it:

   ```bash
   ditto build/Build/Products/Release/Minuta.app /Applications/Minuta.app && open /Applications/Minuta.app
   ```

A welcome window asks for the microphone, system audio recording and calendar, and offers to open Minuta at login. The first transcription takes a few minutes while macOS compiles the model for the Neural Engine. After that, a one-hour call takes about five minutes.

Tests: `cd MinutaCore && swift test`.

A command-line tool for development transcribes a recording folder: `cd MinutaCore && swift build -c release --product minuta-transcribe`, then `MINUTA_DEBUG=1 .build/release/minuta-transcribe <folder>`.

## Files

| What | Where |
|---|---|
| Transcripts | `~/Documents/Minuta Transcripts/` (change it in Settings) |
| Audio while recording or transcribing | `~/Library/Application Support/Minuta/Recordings/`, deleted once the transcript is saved |
| Models | `~/Library/Application Support/Minuta/Models/` |
| Event log (no transcript text) | `~/Library/Logs/Minuta/minuta.log` |

## Known limits

- All Safari tabs play sound through one shared WebKit process. During a Meet call in Safari, audio from other Safari tabs is captured too.
- With laptop speakers instead of headphones, your mic also hears the other side, so some of their words can show up as yours.
- Mixed Spanish and English within a single sentence is handled well, but not perfectly.

## License

MIT. See [LICENSE](LICENSE). WhisperKit and SpeakerKit are MIT-licensed by Argmax, Inc.
