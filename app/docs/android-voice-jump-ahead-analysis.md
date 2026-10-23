# Why the highlight can jump ahead of the speaker (Android Voice mode)

Question: in Voice mode the highlight twice moved a few words ahead of what was spoken. The reference app uses the same
matcher, so why does ours?

## What was checked

1. **Our tracker against the reference code again.** `ScriptTracker` was compared with the raw decompile
   (`~/projects/vp-apk/work/ju3-simple/ju3.java`): history trim and its corroboration test, 6-word tail, incremental score
   growth with the one-extra-word tolerance, the offset thresholds, the 1500 ms repeat guard, the best-candidate rule, the
   cursor advance and the window counter. All match the handoff and our port.
2. **What the reference does with the result.** `ud.q` passes the recogniser's first hypothesis, unmodified, to the tracker
   and calls the UI with `d - 1`; `td3` posts it to the main thread behind a generation check and `rg3.m0(idx + 1)` stores
   `d` directly. There is no smoothing, rate limit or second confirmation between the matcher and the highlight (the Compose
   scroll/highlight animation layer was not examined). Their highlighted word is `d`, the next word to speak; ours marks the
   last matched word `current` and `d` as `predicted`.
3. **Intent builder (`ud.A`).** Biasing is the same: the next 150 non-skipped script words, de-duplicated. They also feed the
   recogniser the shared recording audio via `EXTRA_AUDIO_SOURCE` (48 kHz) when a video is being recorded, and pass
   `SEGMENTED_SESSION` as a string. Ours listens with its own microphone.

## What causes forward jumps in the algorithm itself

A single rule does almost all of it: at offset 2 to 4 ahead of the cursor, **one matching word of 4 or more letters is
enough** (`score == 1 and len >= 4`). Any recognition error that happens to be a script word from just ahead moves the
cursor there.

Biasing makes such errors likely, because a biased recogniser's mistakes are drawn from the upcoming script vocabulary.

Simulation (scratch script, real `ScriptTracker` and `VoiceMatcher`; 300 reads of the 77-word demo script, cumulative
partials, an error = the heard word is replaced by a random script word 2-31 words ahead; "jump" = cursor 3 or more words
ahead of the words actually spoken):

| Words wrong | reference tracker | old `VoiceMatcher` (sherpa fallback) |
|---|---|---|
| 0% | 0/300 reads | 0/300 |
| 5% | 70/300 | 144/300 |
| 10% | 123/300 | 229/300 |
| 20% | 185/300 | 259/300 |

Variants of the tracker at 5% / 10% errors: baseline 70 / 123 of 300; requiring 2 words at offset 2-4 (drop the single-word
tier) 1 / 5 of 300; additionally requiring 3 words at offset 5-8 1 / 1 of 300. Caveat: the error model is an assumption, not
measured recogniser output, so the absolute rates are a stress test; the ranking of causes is what the numbers show.

## Why ours may differ from the reference app

* The algorithm is the same, so the single-word tier exists there too; a different input stream is the likely difference (its
  recogniser sees the shared recording audio; ours records its own and, on the Record screen, runs beside the camera's capture).
  Their jump rate was not measured here.
* **Which engine ran.** Without Google's offline English pack the recogniser fails with `LANGUAGE_PACK_ERROR` and Voice mode
  falls back to sherpa with the **old** `VoiceMatcher`, not the ported tracker (the emulator used for testing had no pack:
  `adb logcat | grep LANGUAGE_PACK`). That matcher jumped about twice as often in the simulation.
* Not verified: real hypotheses from a phone. Capturing them (log the hypothesis, the cursor and the accepting rule on a
  device) is the way to confirm the cause.

## Options (not applied; the request was to follow the reference)

1. Require 2 words at offset 2-4 (and 3 at 5-8): removes nearly all simulated jumps, deviates from the reference.
2. Require the same match in two consecutive partials before accepting a far single-word jump.
3. Shrink the biasing list so errors stay near the cursor.
4. Show `d` (next word) as the highlight like the reference, if the perceived lead is the dim `predicted` word.

## Changes made to match the reference's pipeline (Android)

The matcher itself was already identical, so the pipeline around it was aligned instead:

* **One tracker whichever recogniser runs.** The reference feeds the same tracker from every backend. Ours dropped to
  sherpa plus the old, jumpier `VoiceMatcher` whenever the on-device recogniser was unavailable. On Android the sherpa fallback
  now reports its whole running hypothesis (`SherpaSpeechEngine.hypotheses`) and goes through `ScriptTracker` too, with the same
  utterance resets. Other platforms still use `VoiceMatcher`. Recorded-audio mode is unchanged.
* **Offline pack download.** On a missing-language error (`SpeechChannel.downloadModel`) the speech service is asked to download
  the offline pack (`triggerModelDownload`, API 33+), as the reference does, so a later session can use the on-device
  recogniser. Audio is not uploaded.
* **Not copied: the system-recogniser fallback.** The reference falls back to the system `SpeechRecognizer`, which can send audio
  to a server. That conflicts with the decision that speech stays on-device (`SPEECH_ENGINE_DECISION.md`), so it was left out
  pending an explicit decision.
* Still different from the reference: it feeds the recogniser the shared recording audio (`EXTRA_AUDIO_SOURCE`); ours records
  its own. Only build and static checks were run; no device or emulator was available to test jumping.

