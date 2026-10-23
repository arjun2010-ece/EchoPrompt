# Android voice tracking: implementation notes

Implements `voice-tracking-handoff.md` for Voice mode on Android only. iOS, macOS, Windows and the
Recorded-audio mode are unchanged and still use sherpa-onnx.

## What changed

| Piece | File |
|---|---|
| Tracker (port of the reference matcher, `ju3`) | `lib/core/matching/script_tracker.dart` |
| Dart wrapper for the platform recogniser | `lib/services/speech/android_speech_recognizer.dart` |
| Native recogniser (Kotlin, `SpeechRecognizer`) | `android/app/src/main/kotlin/com/echoprompt/app/SpeechChannel.kt`, wired in `MainActivity.kt` |
| Voice-mode wiring | `lib/features/prompter/prompter_controller.dart` (`_startNativeVoice`, `_onHypothesis`) |
| Package visibility for `RecognitionService` | `android/app/src/main/AndroidManifest.xml` (`<queries>`) |

## Why the old Android path was late and wrong

The sherpa path emitted *new words* from a small streaming model that drops the first ~0.6 s of speech
and decodes in ~320 ms steps (see `VOICE_LATENCY.md`), and `VoiceMatcher` then consumed those words one by
one. The reference instead takes the recogniser's **whole running hypothesis on every partial result** and
re-matches its last 6 words against the script, so a late, revised or misheard word cannot strand it.

## Design

```
SpeechRecognizer (on-device, partials) --> SpeechChannel.kt --EventChannel--> PrompterController._onHypothesis
        ^ BIASING_STRINGS (next 150 words)  <--MethodChannel setBias--  ScriptTracker.biasingWords()
```

* **Recogniser (reference backend B).** `createOnDeviceSpeechRecognizer` (API 31+), partial results, free-form
  `en-US`, `EXTRA_PREFER_OFFLINE`, 2000 ms silence lengths. On API 33+ it uses a segmented session (no gap
  between phrases; each segment is an utterance boundary) and `EXTRA_BIASING_STRINGS`. Below 33 each result
  ends the session and a new one starts after 250 ms. Errors restart after 250 ms (2000 ms when the
  recogniser is busy / rate limited); a 2000 ms watchdog restarts a session that never reports ready.
  Permission and missing-language errors stop listening and surface as the status message.
* **Tracker.** `ScriptTracker.update(text, nowMs)` is the handoff §4 algorithm: history of 3 words, tail
  trimming with corroboration, 6-word tail, n-gram score with one tolerated extra spoken word, the offset
  threshold table, the 1500 ms same-word repeat guard and the best-candidate rule. Cursor is clamped, the window
  is 150 eligible words. The §5 worked examples were run against it and all give the documented cursors.
* **Controller.** Unchanged partials are not reprocessed. A final result (or a recogniser restart, sent as an
  empty final) calls `endUtterance()`, which resets the repeat anchor. The tracker re-syncs to
  `progress.confirmedWordIndex` before every update, so taps (`seekTo`), restarts and a new session need no extra
  hooks and a stale position can't survive. The highlight is the tracker's last matched word; `finished` is
  set when the cursor passes the last word (so trailing punctuation-only entries don't block it). The
  "lost" timer works as before.
* **Fallback.** If the device has no on-device recogniser (API < 31, or the offline English pack isn't
  installed) `isAvailable()` is false and Voice mode runs the existing sherpa path unchanged. Audio is never sent
  to a server, per the on-device decision in `SPEECH_ENGINE_DECISION.md`.
  `isAvailable()` can still be true while Google's English pack isn't downloaded (seen on an API 37 emulator:
  recogniser error 13, `LANGUAGE_PACK_ERROR`). That error (and 12) is raised as `NativeRecognizerUnavailable`;
  the controller then restarts Voice mode on sherpa for the rest of the session instead of stopping.
* **`warmUpVoice()`** now binds the recogniser service instead of loading sherpa when the platform recogniser
  is available (sherpa is warmed only for the fallback).

## Deviations from the reference (deliberate)

1. **Apostrophes are removed before splitting spoken text.** The reference splits on every non-letter, so
   "don't" becomes `don`,`t` and can never equal the script's `dont`. Stripping `'`/`’` first makes both sides
   agree. Not in the reference.
2. Backward matching now follows the reference: it is **off** (`allowBackward` defaults to false), so the cursor
   only moves forward on this path. The tracker still supports the wide mode (4+ words within 20 back, else 5+):
   pass `allowBackward: true` in `begin()` to turn it on. A reader who repeats an earlier passage is therefore not
   followed backward with the on-device recogniser (the sherpa fallback still follows).
3. **Own microphone.** The reference shares one `AudioRecord` between recording and recognition. The platform
   recogniser opens its own, so on the Record screen the camera's capture and the recogniser run side by side
   (same app, allowed since Android 10). The camera plugin's audio stream is not used on this path.
4. The `skip` flag on a script word is "no letters or digits" only.

## Not done / limitations

* **Checked only on an emulator without the English pack** (so only the sherpa fallback ran; the on-device path has not been seen working). Verified: `flutter analyze` (no new issues), the debug APK builds
  (Kotlin compiles), and the tracker against the handoff's worked examples. Latency and accuracy on real phones, the
  two simultaneous microphone captures on the Record screen, and whether a device plays a recogniser start/stop sound
  (which the camera could record) all need a check on the owner's phone. If the sound is audible, feed the camera
  audio to the recogniser with `EXTRA_AUDIO_SOURCE` (API 33+) instead.
* Biasing is refreshed when a session starts and after each final result, not mid-segment, so in a long single
  session the bias window can lag the cursor. Biasing only exists on API 33+.
* Voice commands (handoff §6: "go start", "go next", …), the sound-activation mode and the per-locale phrase tables are
  not implemented; the app is English only.
* Numbers/symbols spoken aloud ("forty percent" for `40%`) are not expanded as `VoiceMatcher` does; a recogniser
  that writes digits matches, one that spells them out is bridged only by the n-gram tolerance.
* Handoff §7 uncertainties remain (partial de-duplication, the 300 ms stale-chunk rule): no audio queue exists here,
  so there are no chunks to discard.
* Pre-existing, left alone: `flutter analyze` reports `depend_on_referenced_packages` for
  `tools/voice_latency/voice_latency_test.dart`.

## Record screen behaviour (Android, Voice mode)

* The prompter overlay spans the full screen width (no side margins; only its bottom corners are rounded).
* The microphone listens from the moment the screen opens and is switched only by the play/pause button in the control
  bar. Record, pause/resume recording, stop and the close-while-recording dialog no longer start or stop it
  (`_micIsIndependent` in `record_screen.dart`). Editing the script keeps the mic as it was; switching to Voice turns it on;
  it is released when the app goes to the background and resumes on return. Audio and Normal modes and other platforms are
  unchanged.
* Fixed: `EXTRA_SEGMENTED_SESSION` is a string naming what ends a segment (the reference passes the silence-length extra's
  name); the first version passed `true`, which the recogniser ignores, so sessions were not segmented.
* Checked: `flutter analyze` and a debug build. Not run on a device or emulator (none was available).

See `android-voice-jump-ahead-analysis.md` for why the highlight can run ahead of the speaker.

