# Android Voice mode: parity with the reference recogniser

Android only. Compares our Voice mode with the reverse-engineered VoicePrompter engine (`~/projects/vp-apk`,
`work/jadx-out/sources/defpackage/`: `ud` engine, `sd` listener, `qd` watchdogs, `a34`/`or` shared audio, `ou3`/`uj1`
tokenizer, `rg3` language) and records what was changed to match it. The matcher itself (`ScriptTracker`, port of `ju3`)
was already identical: see `android-voice-tracking-implementation.md`.

## Analysis: why a spoken word was sometimes not picked up

The matcher was not the cause. The differences were in the pipeline around it.

| # | Difference | Effect | Decision |
|---|---|---|---|
| 1 | Language | None in practice (see below) | Already the same, no change |
| 2 | Only one watchdog (2 s) instead of three | A stalled service silently stopped matching | Ported all three, same timings |
| 3 | No session id on callbacks; fixed 250 ms restart | Stale partials fed in; clipped start of the next phrase | Ported session ids, 100 ms restart and back-off |
| 4 | Sherpa fallback with the exact-match tracker (WER ~21%) | More misses on phones without the offline pack | Removed from Android Voice mode; the system recogniser is the fallback, and phones with neither get an alert |
| 5 | `[stage directions]` and emoji waited for | Cursor stuck on words nobody says | Ported the skip rule |
| 6 | Two microphones while recording | Some phones degrade or silence one capture | Recogniser now reads the recording's own audio |

**Correction to the first analysis (item 1).** The reference's language setting is "auto". It resolves the language
from the *script text* (`rg3.e0`): Latin text with no language-specific letters gives no detected language, `g0` returns
null, and the language becomes **`en-US`** (`rg3:834`). The device locale is only used to choose between variants of a
detected non-English language. So for an English script the reference also uses `en-US`, as we do. The script-language
detection is not ported (the app is English only).

## What was changed

### Recogniser engine: `android/app/src/main/kotlin/com/echoprompter/app/SpeechChannel.kt`

A line-by-line port of `ud` / `sd` / `qd`:

* **Session ids.** Every callback belongs to the session that started it (`generation`, reference `k`); callbacks of a
  session that ended are ignored. A restart bumps the id.
* **Watchdogs** (all recover through `recover`, reference `D`):
  * 10 s after a session starts: "service did not become ready" (cleared by any callback);
  * 10 s after speech begins with no result: "speech detected but no recognition result arrived" (not used while reading
    shared audio; refreshed by non-blank partials);
  * 8 s after end of speech: "service never completed the utterance" (refreshed by partials; does not count as a failure).
* **Restart pacing.** 100 ms after a result or end of a segmented session; error delays as in the reference (150 ms
  no-match/timeout, 400 ms busy, 1 s full restart, 200 ms recreate). Six restarts within 1.5 s back off for 2 s.
* **Error table** (`onSessionError`): the reference's `sd.onError`, including the five-failures-in-a-row give-up
  ("Speech recognition is not responding"), the client-error / repeated-error fallback that drops the silence-length
  and segmented-session extras, and the quirk that error 9 with permission falls through after the retry.
* **Intent** (`buildIntent`, reference `A`): free-form, `en-US`, partial results, word timing on API 34+, max results 1,
  `PREFER_OFFLINE`; on API 33+ either the shared audio source (48 kHz, mono, PCM16, `SEGMENTED_SESSION` naming the audio
  source) or the silence lengths as **ints** (2000) with `SEGMENTED_SESSION` naming the silence key; biasing strings are
  de-duplicated and sent only when non-empty. (The silence lengths used to be longs; the reference sends ints.)
* **Reset at session start.** An empty final is emitted when a session starts, so the tracker re-anchors (reference
  `ju3.c(d)`).
* **System recogniser fallback** (reference `x`, `v`, `I`/`J`): the on-device recogniser is used when the phone has one.
  When it can't handle the language (errors 12/13), keeps failing (two errors in a row), can't access audio, can't start,
  or a watchdog fires, the engine switches to `SpeechRecognizer.createSpeechRecognizer` for the rest of the session. That
  recogniser **may send audio to Google's servers**. Error 13 first calls `triggerModelDownload` (API 34+ with the
  logging listener, as the reference does). The system recogniser's own errors follow the `!J` branches: language errors
  and a missing microphone permission end the attempt with a message, other failures restart.

### Shared audio in Voice mode: `packages/echoprompter_camera/.../SpeechAudioBridge.kt`, `EchoprompterCameraPlugin.kt`

The reference feeds the recogniser from its own microphone capture whenever Voice tracking runs on Android 13+
(`wd3.E` is true for voice tracking, `wd3.f` opens the capture `a34` with a pipe), not only while recording. We do the
same: the camera plugin's 48 kHz mono capture (the one a take records) also writes into a pipe (capture thread, queue
of 12 buffers dropping the oldest, writer thread), and `SpeechChannel` passes a duplicate of the pipe's read end as
`EXTRA_AUDIO_SOURCE`. The capture starts when Voice mode starts listening and stops when nothing needs it any more
(no listener, no take, no sample stream). Like the reference's `a34` it records with the plain `MIC` source (it was
`CAMCORDER`, whose gain control raises room noise) and an `AudioRecord` buffer of twice the minimum, and the queue
holds about 0.5 s of audio (26 × 20 ms; the reference keeps 12 reads of at least 4096 bytes). The pipe carries
**16 kHz** (a 47-tap low-pass decimator, flat to 5 kHz, more than 60 dB down above 9 kHz); the take keeps 48 kHz.

A take starting or ending does **not** restart the recogniser (see "Deliberate differences").

Why it matters (found from the owner's test, 2026-10-23): with the recogniser opening the microphone itself, every
session start or restart (each result, each "no match" during silence, roughly every 2.5 s on the emulator) dropped
the audio until the new session was ready, and a fresh session answered late. With the pipe, the session does not end on
silence (the segmented session ends with the audio source), and audio that arrives while a session starts is kept in
the pipe and recognised as soon as it is ready.

Failure handling is the reference's `y` / `P`:

* loud audio (RMS ≥ 0.008) for 8 s with no transcript, or two audio / client / busy errors, first moves the on-device
  recogniser to the system one; if that also fails, the recogniser opens the microphone itself, **but only on the Read
  screen** (the reference's Prompter mode). On the Record screen (its Video mode) it stops with "This speech service
  cannot recognize recording audio." (`micFallback`, sent by the controller when it listens);
* if the shared audio had worked before, it is retried with a back-off (1 s doubling to 8 s) instead.

Related fix: closing the Record screen now pauses the prompter on Android (`record_screen.dart` `dispose`). Before, Voice
mode kept listening, with the microphone open, after the screen was left.

### Script words: `lib/core/matching/script_tracker.dart`

Port of `uj1.k` / `ou3`: text from `[` to the next `]` (it may span words and lines) is skipped; a word containing an
emoji (the `nu3` ranges) is skipped whole; so are words without letters or digits. Skipped words are empty in the clean
list, so matching, the cursor and the bias words step over them. Checked with a scratch script: the cursor moves from
"…the" over `[pause for effect]` and "😀" to "show"/"today".

### Unsupported phones: `prompter_controller.dart`, `lib/ui/voice_unsupported_dialog.dart`

The sherpa path (and `SherpaSpeechEngine.hypotheses`) was removed from Android Voice mode. `isAvailable` is true when the
phone has an on-device or a system recogniser. If it has neither, or the system recogniser can't recognise English
(`language`), `PrompterState.voiceUnsupported` turns on and the Read and Record screens show "Voice mode isn't available
on this phone" once per attempt (Normal mode still works). Sherpa is still used for Audio mode (file transcription) and
on the other platforms.

## Deliberate differences from the reference

* **Privacy decision reversed (2026-10-23).** Speech used to be forced on-device and never uploaded; the owner chose to
  match the reference and accept the system recogniser's possible network use in exchange for reaching more phones. Any
  copy that promises "audio never leaves the phone" must not be shown for Android Voice mode.
* Shared audio only on API 33+ (that is where `EXTRA_AUDIO_SOURCE` exists), as in the reference. Below that the
  recogniser opens the microphone itself, even while recording.
* **No recogniser restart when a take starts or ends.** The reference restarts its engine there (`wd3.F` calls `L`,
  then `I` → `J`), but only after its 3-2-1 countdown (`wd3.H`), when nobody is speaking. Our Record button has no
  countdown and the camera takes up to ~3 s to start, so the same restart landed mid-sentence: the words the old session
  had already read from the pipe were lost and only appeared highlighted when the next sentence made the tracker jump.
  The audio source is the same capture before and after the take, so nothing needs restarting.
* The capture keeps preferring the built-in microphone (existing decision: Bluetooth output keeps A2DP quality and the
  Audio mode's headphone routing relies on it). The reference prefers a USB, wired or Bluetooth headset microphone.
* The capture reads 20 ms at a time; the reference reads at least 4096 bytes (~43 ms). Smaller reads only lower latency.
* **16 kHz to the recogniser, not 48 kHz.** Google's on-device engine (SODA) runs at 16 kHz. Given 48 kHz it logs "Must
  re-create SODA due to changed sample rate. This should not occur for normal use cases." and rebuilds itself at every
  session start, during which it takes no audio. Measured on the emulator (see "Owner's report 3").
* The video's audio source is `CAMCORDER` (existing), the reference uses `MIC`.
* Voice commands, the language auto-detection and the sound-activation mode are not ported.
* A script word that is only partly inside brackets (`word[aside]more`) is one word here, three entries there.

## Verification

* `flutter analyze`: clean apart from the existing `tools/voice_latency` info.
* `flutter build apk --debug`: Kotlin (app and camera plugin) compiles.
* Emulator (API 37, a camera and microphone on the host), run in two stages:
  * Without the English pack: play in Voice mode logged `onError 13`, then `falling back to system recognizer` and
    `created recognizer: system`; Google's service offered its own "Download English (US) update" prompt.
  * After the pack downloaded (the download progress is in the log): `created recognizer: on-device · en-US · system
    microphone`, `onReadyForSpeech`, segmented results, and `onError 7` (no match) restarting the session. The prompter
    highlighted the spoken words ("Replace this").
  * With a take recording: `created recognizer: on-device · en-US · shared audio`, the recogniser reached
    `onReadyForSpeech`, `onBeginningOfSpeech` and segment results from the pipe; after stopping, it went back to `system
    microphone`; the take saved to the gallery.
* Tracker bracket/emoji skipping: scratch script, as above.
### Fault and accuracy tests (2026-10-23, emulator API 37)

Run with temporary instrumentation that has since been removed: a broadcast receiver that calls the session listener
(errors, begin/end of speech, "drop this session's callbacks" to imitate a stalled service) and a hook that replaces the
camera's microphone samples with synthesized speech (macOS `say`, 48 kHz PCM16, streamed in real time into the same
recording-audio pipe the recogniser reads). The emulator could not hear the Mac's speakers, hence the injection.

| Behaviour | Result |
|---|---|
| Speech watchdog | Fired 10.0 s after beginning of speech: "speech detected but no recognition result arrived" → on-device gave way to the system recogniser |
| Utterance watchdog | Fired 8.0 s after end of speech: "service never completed the utterance" → session restarted 400 ms later (system branch) |
| Ready watchdog and give-up | 10 s per session ("service did not become ready"): on-device → system, then five more failures → stopped, status "Unavailable" |
| Restart back-off | Rapid error bursts: after six restarts inside 1.5 s the next session started 2.0 s later |
| Shared audio, two audio errors | on-device → system recogniser (still shared audio) |
| Shared audio, two more | dropped to the recogniser's own microphone (`falling back to recognizer-controlled mic`). Run before the Read/Record distinction was added: on the Record screen this now stops with a message instead, and the Read-screen fallback was not run again |
| Shared audio had worked, two audio errors | `Retrying previously working shared recognition in 1000ms` |
| Loud audio (440 Hz tone), no transcript | 9.1 s after it started (1 s silence + 8 s): on-device → system recogniser |
| Take starts / ends | Recogniser restarts on `shared audio` / `system microphone` |

Accuracy and speed with the demo script (78 words, ten phrases, 0.45 s pauses), measured from the log of recogniser
results and tracker updates; "lag" is the time from the end of a phrase's audio to the highlight reaching its last word:

| Voice | Words followed | False jumps (> 2 words) | Backward moves | Lag per phrase |
|---|---|---|---|---|
| Samantha en-US, 165 wpm | 78 / 78 | 0 | 0 | −0.12 … +0.36 s (median ≈ 0.2 s) |
| Aman en-IN, 190 wpm | 78 / 78 | 0 | 0 | +0.15 … +0.34 s |
| Daniel en-GB, 230 wpm | 77 / 78 (the last word came after the capture stopped) | 0 | 0 | −0.10 … +0.30 s |

* The channel and the tracker add 0 to 20 ms between a recogniser result and the highlight. The remaining delay is the
  recogniser's own (about 0.2 to 0.35 s after a word); the reference uses the same recogniser.
* The scroll after the highlight: ours eases toward the line with a 0.25 s time constant, the reference runs an 850 ms
  animation with an ease-out curve (`ht2`, interpolator 0, 0, 0.2, 1). Neither is slower than the other, so nothing was
  changed.
* The one stall: the product name "EchoPrompter" in the first phrase. The recogniser writes "Echo prompter" (or "Echo Grant"
  at 230 wpm), which never equals the script word, so the highlight waited 1.0 to 1.2 s on "to" until "replace" arrived.
  The reference does the same (its tokenizer also keeps "EchoPrompter" as one word), so it was left alone.
* Not tested: speech from a real microphone on a real phone, the video file's audio track, API levels below 33.

### First-word speed (2026-10-23, after the owner's report)

Owner's test, sentence "We are attaching the screenshot of a competitor teleprompter app.": the reference highlighted
"We are" while "attaching" was being said; ours only started between "screenshot" and "of a". Measured on the emulator
after the change, with the sentence injected into the capture (macOS `say`, 165 wpm; "We are" lasts 0.48 s):

| Case | "We" highlighted | "We are" highlighted | Reached "a" (word 7) |
|---|---|---|---|
| Record screen open, listening for a few seconds, then speaking | 0.61 s | 0.71 s | about 2.2 s |
| Play pressed, speaking 0.3 s later (brand-new session) | 1.09 s | 1.20 s | 2.1 s |
| Camera record pressed, speaking 0.3 s later (with the take-start restart, since removed) | 0.37 s | 0.61 s | 2.18 s |

Times are from the start of speech. In every case "We are" lights up while "attaching" is being said. A brand-new
session answers its first partial later (the recogniser's own warm-up); the buffered audio is then recognised in a
burst, so nothing is lost.

### Owner's report 2 (2026-10-23): half a sentence highlighted; sometimes nothing at all

**Evidence.** The owner's own emulator log (real voice, read-only copy): one recogniser session per listening start, no
errors, no watchdog recoveries, segments every 0.5 to 2 s, and four engine restarts during the test. On my emulator, a
take started and the recogniser restarted ~3 s later, mid-sentence; the new session never received "teleprompter app",
which the old one had already read from the pipe, so those words stayed un-highlighted (reproduced, log above).

**Fixed (all traced to the reference, or to a reference behaviour that only works because of its countdown):**
1. No recogniser restart when a take starts or ends (see "Deliberate differences").
2. Every recogniser result goes to the tracker, as `ud.q` does (we used to skip a result whose text had not changed).
3. Bias words are the clean forms over the next 150 script entries, as `ud.A` builds them from `ju3.c`.
4. Capture: `MIC` source, buffer and queue length as `a34` (above).

**Result** (emulator, the owner's two sentences with room noise and a 0.9 s pause, a take started and speech begun 0.3 s
later): all 20 words highlighted in order, each 0.2 to 0.5 s after it was said; "app" lit at 4.24 s, before the second
sentence began at 4.85 s. Listening carried on after the take ended (same session), the take saved with its AAC audio
track, and closing the screen released the microphone.

**"Nothing at all" — what else causes it, in both apps.** Backward matching is off by default in the reference too
(`allowBackwardScrolling` false). If the highlight is already further on (for example at the end after a full read, or a
take ago), speaking an earlier passage moves nothing until Restart (or a tap on the word). The reference also offers
spoken commands for this ("go start", `enableVoiceCommands` true by default); we have none yet.

### Owner's report 3 (2026-10-23): still half sentences; a short sentence swallowed

**Where the two apps were compared.** None of the owner's emulators (Pixel_6, Pixel_7, Small_Phone, Pixel_10_Pro) has the
reference installed, so it was most likely run on a phone, and ours on the emulator. The code paths are now the same
(the tracker was re-checked against the low-level decompile of `ju3.b`, instruction by instruction; audio has no effects
or gain in either app), so the comparison mixes two very different speech engines' start-up speeds.

**Real acoustic test.** The emulator does hear the Mac's microphone, so the test played speech from the Mac's speaker
(`say`, the owner's two sentences) into it. Google's own log (`SodaSpeechRecognizer`, `SodaAudioPusher`) showed why
words disappear on the emulator:

| Session start | 48 kHz (reference) | 16 kHz (now) |
|---|---|---|
| Warm restart: until the engine takes audio | 0.56 to 1.14 s (5 trials), plus a full engine rebuild each time | 0.07 to 0.30 s (5 trials) |
| Speaking 0.3 s after Play: first word caught | 4 of 5 trials ("We are" lost once) | 5 of 5 |
| Cold service (engine not loaded), speaking at once | the whole first sentence lost | "We are attaching the" lost, rest caught |

Once the engine is running both rates recognise the same (three warm trials each); the misses left are mishearings
through the speaker and microphone ("screen" for "screenshot of a", "attacking", "especially"), which the reference
would hear the same way. A cold start (the speech service not running, common on a 2 GB emulator) still costs about
1.5 s; neither app can hear during it.

**Also found (not changed).** After a take is saved, the "Saved to your gallery" snackbar has a Share action, so it stays
until dismissed and covers the Record screen's bottom controls (Pause/Play, Restart, Settings, Close) and the Studio's
Record button. While it is up, Restart can't be pressed, so a reader who starts again from the top sees "Lost your place"
and nothing highlighted.

### Side-by-side test on one emulator (2026-10-24)

Both apps on the same Pixel_10_Pro emulator, the owner's own 121-word script in both, and the same recorded speech (its
first three sentences, 30 words, 9.9 s) played from the Mac's speaker into the emulator's microphone. The reference is
1.7.1 from the Play Store (the decompile is 1.7). Ours: the clean build plus logging of recogniser results; the reference
was read from screenshots (one raw screenshot a second; video recording, even host-side, starved the speech engine and
was abandoned). Words reached out of 30:

| Scenario | Reference (48 kHz) | Ours (16 kHz) |
|---|---|---|
| Speaking into a running session (3 runs) | 30, 30, ~25 | 29, 30, 30 |
| Speaking 0.3 s after Play (3 runs) | ~23, ~29, ~30 | 28, 30, 29 (first word lit at 0.8 s every time) |
| Cold start: speech service stopped first (2 runs) | **1** ("We" only), ~25 (nothing moved for 5 s) | 30, 30 (first word at 3.0 s and 1.9 s) |

The reference confirmed on this emulator what was ported: it reads its own capture through `EXTRA_AUDIO_SOURCE`
("created recognizer: on-device · en-US · shared audio") even without a take, and Google's engine logs "Must re-create SODA
due to changed sample rate" for it and starts taking its audio ~1.0 s after a session starts. On this emulator the
reference also swallows sentences after a cold start (the owner's Issue 2); ours does not.

**CPU found during the test.** Idle and listening on the camera screen the reference used ~4–8 % of a core, ours ~93 %.
Cause 1 (fixed): the prompter text's frame ticker ran forever and redrew the whole prompter 60 times a second even when
nothing moved; it now stops when the text is still and restarts when it has to move (`prompt_surface.dart`, Android only).
The Preview screen went from 93 % to 0 %. Cause 2 (investigated, not changed): the live camera preview. Measured with Flutter's frame timings on
the Record screen: 11–13 frames a second (one per camera frame the raster thread can keep up with) at 76–90 ms of raster
work each, so the raster thread is always busy. Without the prompter overlay a frame still costs ~72 ms: nearly all of it
is compositing the camera texture on the emulator's emulated GPU (the overlay adds ~15 ms). Tried and measured, none
helped: a 1280×720 preview buffer (recording kept at 1080p), the camera at 15 fps, the overlay without its fade
(`ShaderMask`), and the Skia renderer instead of Impeller. Only the reference's approach would remove it: a native
Android camera view under the Flutter UI (a platform view), so camera frames never pass through Flutter. That is a large
change and was not started. On a phone's real GPU compositing a camera texture costs a few milliseconds a frame, so this
mainly affects the emulator; in the side-by-side runs above ours tracked as well as the reference despite it.

**Notes for testing on the emulator.** An Android Studio launch may not pass the Mac microphone in: turn on "Virtual
microphone uses host audio input" (or `adb emu avd hostmicon`). The Mac's output volume matters (35 % was too quiet, 80 %
worked). Results vary between runs because the speech comes through a speaker and a laptop microphone.

## End-to-end comparison with the reference

| Stage | Reference | Ours | Same? |
|---|---|---|---|
| Script words | `uj1.k` / `ou3`: whitespace, `[brackets]` and emoji skipped, clean = lowercase letters and digits | `scriptWords` + `ScriptTracker._cleanWords` | Yes (a word only partly in brackets is one entry here) |
| Language | "auto" → `en-US` for English text | `en-US` | Yes |
| Audio | `a34`: `MIC`, 48 kHz mono PCM16, queue → pipe → `EXTRA_AUDIO_SOURCE` whenever voice tracking runs (API 33+) | camera plugin capture (`MIC`, 48 kHz), queue → pipe at **16 kHz** | Same source and queue; 16 kHz on purpose (above) |
| Recogniser | on-device, else system; intent `ud.A` | `SpeechChannel.buildIntent` | Yes |
| Session handling | `ud` / `sd`: session ids, restarts 100 ms, back-off, error table | `SpeechChannel` | Yes |
| Watchdogs | `qd`: 10 s ready, 10 s speech, 8 s utterance | same | Yes |
| Shared-audio failures | `y`, `wh1` case 1 | `sharedFailed`, `activityCheck` | Yes |
| Restart on take start/end | yes, after a countdown | no | **Different on purpose** |
| Hypothesis → tracker | every result, blank ignored (`ud.q`) | every result, blank ignored | Yes (fixed today) |
| Segment end | `ju3.c(d)` resets the anchor | `endUtterance()` | Yes |
| Tracker | `ju3.b`: history 3, tail 6, thresholds, 1.5 s guard, window 150, backward off | `ScriptTracker.update` | Yes (apostrophes kept together here) |
| Bias | clean forms, next 150 entries, de-duplicated, at session start | same | Yes (fixed today) |
| Position update | `td3` → `rg3.m0(d)`, only while playing and not dragged | `PromptReadingProgress.synchronized` | Equivalent (we show the last matched word and the next one) |
| Voice commands | on by default | none | **Missing** |
| Countdown before a take | 3 s | none | **Missing** |

## Future scope

An offline fallback (Vosk) for phones without on-device recognition: `plan/cross-platform-plan.md`, Phase 6.
