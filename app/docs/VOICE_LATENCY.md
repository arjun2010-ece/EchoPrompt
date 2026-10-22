# Voice mode: highlight latency

Findings from measuring how quickly the highlight follows the speaker in Voice mode
(the Record screen on mobile, the prompter on desktop). Read this before changing the
recognizer, the emitter, the matcher or the Start sequence, so the same ground is not
covered twice.

Measured October 2026 on a Mac with synthetic voices, cross-checked on a few real
recordings. **Nothing here was measured on a phone.** Treat the absolute numbers as a
desktop lower bound; the comparisons between settings are the reliable part.

See also `SPEECH_ENGINE_DECISION.md` for whether a platform recognizer should replace or
supplement sherpa.

## The pipeline

```
mic (camera plugin, 16 kHz mono, ~20 ms chunks)
  -> SherpaSpeechEngine.listen   streaming zipformer 20M, decodes in ~320 ms steps
  -> LiveWordEmitter             hypothesis text -> words to follow
  -> VoiceMatcher.follow         conservative script matching
  -> PrompterController          progress -> highlight and scroll
```

The model is `sherpa-onnx-streaming-zipformer-en-20M-2023-02-17` (a community "small"
`pruned_transducer_stateless7_streaming`, Apache-2.0). Its decode step is fixed in the
exported ONNX (`decode_chunk_len=32`, `T=39`), so it cannot be made finer at runtime.

## What was wrong, and what changed

Baseline, before any change (Samantha at ~173 wpm, quiet room, warm engine):
highlight lag after a word starts was 0.9 s median and 1.3 s p90, the speaker was about
3 words ahead of the highlight, and the first word of a take lit up 2.4 s after it was
spoken. On the first Start after launching the app, a quick starter waited 4.4 s and
the highlight fell as many as 16 words behind.

Three causes, each fixed in `app/lib`:

1. **The model drops the first ~0.6 s of speech that follows silence.**
   "Hi everyone" arrived as `'RY ONE`, and on a standard recording "AFTER EARLY
   NIGHTFALL" was lost entirely. The same output came from the fp32 and int8 encoders,
   from the official Python API, and from sherpa 1.10.46, 1.12.26 and 1.13.8, so it is
   the model and not the Dart wrapper. It does not depend on how long the silence
   before speech is (0.3, 0.6, 1.0 and 2.0 s all lose the same opening), so pre-rolling
   audio does not help. Fix: `blankPenalty: 3.0` in `SherpaSpeechEngine`, which makes
   the model commit to onset sooner. Median first-word delay went from 2.3 s to 1.0 s
   and the worst case (at -40 dBFS noise) from 6.1 s to 2.6 s. Higher penalties cut the
   worst case further (1.3 s at 6) but penalty 6 invented a word in the silence before
   the speaker started; 3 invented none. In 24 s of loud white noise, 3 produced
   one non-word fragment that cannot match a script word.
2. **The model loaded on the first Start, and the mic attached only after it loaded.**
   `listen()` builds the recognizer lazily, and the plugin's audio stream only starts
   when subscribed, so the opening audio was lost (0.4 s here, likely more on phones)
   and the recognizer then started mid-word. Fix: `PrompterController.warmUpVoice()`,
   called from `RecordScreen._beginPrompter`. `SherpaSpeechEngine.init()` now shares one
   future so a warm-up and an early Start never copy the model files twice at once.
3. **The emitter held the newest word until the next one started.** That is about one
   word of lag. The hold-back existed because a word is spelled piece by piece
   ("fi" -> "five"), but greedy decoding never retracts earlier tokens, so the only
   revision is the last word growing. `LiveWordEmitter` emits a word at once and again
   when it grows. An earlier "emit everything once" variant reached only 97.4% of
   words because it never re-sent the grown word; re-sending fixed that.

### Where the warm-up may be called

Not from `PrompterController.begin()`. `ReadScreen.initState` calls `begin()` while its
route is still animating in, and the model load is synchronous on the UI isolate, so it
would stutter the transition (Voice mode does not even play from that screen). Also,
`begin()` returns early when the session and mode are unchanged, which is the usual
Read -> Record flow, so a warm-up placed after that return would never run. The Record
screen already waits for the transition and the first camera frame before starting the
prompter, so it is the right place.

## Results

Pooled over 10 clips in virtual time (audio time only, no decode cost), noise floor
-60 dBFS, steady speech:

| | before | after |
|---|---|---|
| lag after word start, median / p90 | 0.89 / 1.27 s | 0.66 / 0.88 s |
| lag after word end, median / p90 | 0.61 / 0.78 s | 0.37 / 0.57 s |
| words behind the speaker, median / p90 | 3 / 4 | 2 / 3 |
| words reached | 99.5% | 99.5% |
| words highlighted before being spoken | 0 | 0 |

Real-time end-to-end through `PrompterController`, five clips (four voices), 144-218 wpm, -45 dBFS:
mic attached 0.00 s after Start; first word highlighted 0.8-1.0 s after it was spoken;
lag after word start 0.6-0.7 s median and 0.8-0.9 s p90; speaker 2 words ahead
(3-4 at p90); 0 early highlights. Quick starter on a cold engine: 4.4 s -> 0.8 s to the
first highlight, worst case 16 -> 5 words behind. The warm-up is worth about 1 s on its
own (0.42 s of lost audio and 1.85 s to the first highlight without it, 0.83 s with it).

Words right after a paragraph pause lag about 1.2-1.5 s versus 0.9-1.0 s mid-phrase
(measured before the fixes), so pauses cost a little extra.

## Ruled out (do not re-chase)

- **Endpoint resets (rule1, rule2, rule3).** With endpointing off, every clip gave
  identical results. The empty-hypothesis endpoint at ~1.4 s looks suspicious but is a
  symptom of the dropped onset, not the cause.
- **Input level.** Real clips sit around -25 dBFS RMS with peaks near -5 dBFS; 4x, 8x
  and 16x gain changed nothing.
- **Digital silence.** Adding a -70 to -45 dBFS noise floor changed nothing.
- **Chunk size of the feed.** 320, 1600 and 6400 samples gave the same text.
- **A bigger model.** On the same 10 clips (hold-back policy, lag after word end):

  | model | median / p90 | decode time per second of audio |
  |---|---|---|
  | shipped 20M | 0.65 / 0.82 s | 0.021 |
  | zipformer2 70M (`en-2023-06-26`) | 0.74 / 0.91 s | 0.041 |
  | NeMo FastConformer 80 ms | 0.52 / 0.77 s | 0.231 |

  The 70M model is no better. NeMo is roughly 0.1 s better at about 11x the compute.
  Kroko (`en-kroko-2025-08-06`) was not tested because its license is not stated in
  the release; check it before considering it.
- **Lower `settleSeconds` in the old emitter.** 0.2 s made p90 worse.

## Known limits

- The first word of some voice and phrase pairs still takes about 2.3 s (a British
  voice saying "Hi everyone"). This is the model's residual onset weakness.
- The last word of a script can fail to match. In the test script the model heard
  "video" as "vitio", two letters off, outside the matcher's deliberate one-edit
  tolerance, so `finished` never became true. Not changed.
- Words around numbers that are spoken as several words ("In 2024," and "80%") lagged
  the most in one clip, up to ~2.7 s. Probably the matcher waiting for the whole spoken
  form; not investigated.
- The remaining lag is close to what this model class allows: a ~320 ms decode step plus
  the delay before it commits a token. Whether Apple's or Google's on-device recognizers
  respond faster, and by how much, has not been measured here (see `SPEECH_ENGINE_DECISION.md`).
- The warm-up blocks the UI isolate once (about 0.4 s on the test Mac) when the Record
  screen opens in Voice mode. Moving recognition to a background isolate would remove
  that and also the per-chunk decode cost from the UI thread. Not done.
- Not measured: microphone -> plugin -> platform channel latency, phone CPU (the 0.021
  decode time per second of audio above is for an Apple-silicon Mac), first-launch model
  copy time (the harness points at the bundled files), and real human speakers beyond a
  handful of recordings. The 20 ms chunk size mirrors the native capture buffers but was
  not verified on a device.

## Re-measuring

The harness is `app/tools/voice_latency/`. Its header lists the commands and every
`VL_*` setting. In short: `make_speech.swift` renders a script with a macOS voice to a
16 kHz WAV plus a JSON of per-word start and end times, and
`voice_latency_test.dart` has two tests:

- **end to end** plays the clip as a live mic into the real controller, engine and
  matcher, and reports lag, words behind and first-word delay. Repeat a clip name to see
  the first (cold) run and then a warm one. `VL_WARM=0` reproduces the old cold start.
- **stage breakdown** replays the bare recognizer in virtual time and compares emission
  policies, blank penalties, endpoint settings and models (`VL_MODELS`).

Ground truth: the synthesizer's word-boundary marks agree with the audio energy onset to
within ~100 ms for most words, with a few outliers near 230 ms at comma pauses. That is
small next to the lags above, but do not read differences under ~0.1 s as real.
Synthetic voices are cleaner and more regular than people; confirm any tuning on real
speech before relying on it. The real recordings used came from the model release's
`test_wavs` (LibriSpeech), which are not in the repo.

To compare against a frozen "before", `_HoldBackEmitter` in the harness is a copy of the
old emitter.
