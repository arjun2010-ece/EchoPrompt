# Voice mode: which speech engine?

Status: **open decision**, written October 2026. Nothing in this file is implemented. The
sherpa fixes already made are in `VOICE_LATENCY.md`; read that first for the measured numbers
and the harness. This file records the question that came after: is a better recognizer
available to us, and what should we do about it?

## Why this came up

After the latency fixes, Voice mode still did not feel as responsive as a competing product
(VoicePrompter, below), which the project owner tested on Android and rated "amazing".

`plan/cross-platform-plan.md` section 5 chose sherpa-onnx for consistency, offline use and
privacy, and set a **Phase 0 benchmark gate**: compare sherpa with Apple on 10 recorded
scripts, with targets of word error rate no worse than Apple's plus 3 points and partial-result
latency of 300 ms or less. It also names `AppleSpeechEngine` as an optional engine "only if
benchmarks show it is clearly better". **No result for that gate exists in the repo, so the
choice of sherpa has never been checked against the alternative.**

Where sherpa stands today (Mac, synthetic voices, see `VOICE_LATENCY.md`): the highlight lands
0.37 s median and 0.57 s p90 after a word ends, 0.6-0.7 s after it starts, with the speaker
about 2 words ahead. That is roughly 0.07-0.27 s over the plan's 300 ms target, if "partial-result
latency" is read as delay after the word ends. Accuracy on real people and phone microphones is
unmeasured, and the 20M model garbled a word in one of the two real recordings tried.

## The competitor: voiceprompter.app

Researched from its own site, changelog, store pages and public source. **Nothing was installed
or timed.** Treat everything marked "claim" as marketing.

What was checked directly:

- Made by one developer (Konstantin Suvorov). The web app is on GitHub under **GPL-3.0**
  (`kosuvorov/VoicePrompter`, created Nov 2025, 210 commits, active in Oct 2026). Only the web
  app's source is public. The `android/`, `ios/`, `ipad/` and `mac/` folders hold marketing
  pages, not app code.
- **Web app:** uses the browser's Web Speech API. Its tracker is simple: it takes the last 5
  words of the live transcript (interim and final results together), looks ahead 1-10 script
  words, and advances to the nearest match, skipping a repeat of the previously matched word.
  There is no hold-back, no fuzzy matching and no re-anchoring.

What the product says about itself (claims):

- **Apple apps (Mac, iPhone, iPad):** Apple's Speech framework, on-device.
- **Android:** "Android speech recognition", on-device "when your phone and language support it",
  otherwise the installed system speech service, which "may require a connection". The engine is
  not named. The page does not say how the microphone is shared with in-app 4K recording.
- **Native changelog:** whole-script tracking (follows you when you skip), backward scrolling
  when a section is re-read, suppression of jumps on repeated or short common words, gliding
  scroll between lines, "pacing assistance" that slows on long words, voice commands, and a
  **Sound Scrolling** mode that advances while sound is detected and pauses on silence, with no
  recognition and any language.
- 34 languages on web, 40+ on Android, 60+ on Apple. Free to try with 3 scripts, lifetime option.
- "Trusted by 23,000+ creators" (unverified).
- No latency or accuracy figures anywhere. A "sub-second latency" claim found during research
  belongs to a different app (Laan Labs, "VoicePrompter AI"), not this one.

Not known: the Apple native engine's exact API (Speech framework is named, not which class), the
Android engine, and how any of it performs in numbers.

## What it suggests

Inference, not measurement: VoicePrompter's responsiveness most likely comes from the platform
recognizers, not from clever tracking. Its public matcher is far simpler than ours, and it feeds
live, unfinished transcripts straight to it. We built a lot around a weak recognizer (edit
distance matching, re-anchoring, hold-back policy); a stronger recognizer would make most of that
less necessary.

The product-level choices that are independent of the engine are worth noticing: a no-recognition
fallback mode, scrolling that glides, backward navigation, and tolerance for repeats.

## What transfers and what does not

1. **Sharing the microphone with our camera.** We record video with audio and recognize speech
   from one shared stream (`echoprompt_camera`). iOS and macOS recognizers accept our sample
   buffers, so this is easy there. On Android the system recognizer opens its own microphone by
   default and may fight our capture. `RecognizerIntent.EXTRA_AUDIO_SOURCE` lets a caller supply
   audio, but the Android version it needs and which recognizers honor it are **unverified**.
2. **The privacy promise (decided: always on-device, never uploaded).** Platform recognizers can
   fall back to servers unless forced on-device (`requiresOnDeviceRecognition` on Apple,
   `createOnDeviceSpeechRecognizer` on Android), so any platform engine must be forced on-device
   and must hand over to sherpa when on-device recognition is not available. VoicePrompter hedges
   its own wording on Android ("may need a connection"); we will not.
3. **Revised transcripts.** Apple and Google recognizers rewrite earlier words in their live
   text. `LiveWordEmitter` assumes the text only grows (true for sherpa's greedy decoding), so a
   platform engine needs its own adapter.
4. **Recorded-audio mode** needs a timestamp for every word of a file. Android's recognizer gives
   none, so sherpa's offline model stays for that mode.
5. **Consistency.** Three engines mean three sets of quirks, restarts and device differences
   (Android on-device availability varies by phone and Google app version).
6. **Languages.** Sherpa is English-only at launch and each language is another model download.
   Platform recognizers cover many more languages for free. That is a market gap, not only a
   technical one.

## Recommendations

| # | Recommendation | Status |
|---|---|---|
| 1 | Run the plan's missing benchmark (protocol below) | **Half done**: Apple vs sherpa on a Mac (results below). Android and real speakers still open; Android needs a physical phone |
| 2 | Platform recognizers, forced on-device, with sherpa as fallback, for Windows and for recorded audio. The `SpeechEngine` interface already allows this | **Revised, see results**: Apple is more accurate but not faster, so on its own it will not fix responsiveness. Decide after the Android test |
| 3a | Sound-triggered scroll mode (no recognition, any language, zero lag) | **Dropped by owner decision**: the modes stay Normal, Voice and Audio |
| 3b | Backward re-anchoring: re-reading a passage should move the highlight and scroll back | **Done** (see below) |
| 3c | Gliding scroll | Already present: voice-mode scroll eases toward the target with a 0.25 s time constant (`prompt_surface.dart`). Nothing to add |
| 4 | Stop investing in model swaps | Two larger models were tested and neither was worth it (`VOICE_LATENCY.md`) |

## Done so far: backward re-anchoring

`VoiceMatcher._reread` (in `voice_matcher.dart`) looks behind the highlight, but only when nothing
ahead matched and the unmatched spoken words form a long run: at least 4 matched script words, 3 of
them real words (4+ letters), score 20 or more. In practice a re-read has to be about 5 words long
before the highlight jumps back. Forward matches always win over backward ones.

`PromptSurface` used to take the larger of the old and new scroll target, so it could never scroll
backward. It now follows the target when the *confirmed* word itself moves back; a short-lived
predictive cue still never pulls the text backward. Side effect: tapping an earlier word in
Voice/Audio mode now scrolls back to it too, where before only the highlight moved.

Checked:

- The 10-clip, two-noise-level sweep in `VOICE_LATENCY.md` gives identical numbers before and
  after, so no spurious backward jumps on ordinary reading.
- `tools/voice_latency/matcher_scenarios.dart`: a re-read jumps back and carries on forward; five
  garbled words, a 3-word repeat and a 3-word re-read do not move it back.
- A real recognizer run (`VL_REREAD`, a speaker saying "sorry, let me say that again" and repeating
  a sentence): the highlight jumped from word 28 back to word 14 about 2 s into the repeat, followed
  it to the end, then continued forward.
- The existing controller, matcher, prompt view and desktop prompter tests still pass.

Not checked: a re-read of a phrase that also occurs elsewhere in the script, and any device UI.

## Benchmark results so far: Apple vs sherpa on a Mac

Run October 2026 on one Apple-silicon Mac (macOS 26.6), six clean synthetic clips (five voice
variants, 144-218 wpm, no added noise) played in real time. Apple was forced on-device
(`requiresOnDeviceRecognition`; `SpeechAnalyzer` is on-device by design). Every engine's text goes
through the app's own `LiveWordEmitter` and `VoiceMatcher`, so only the recognizer differs.
`SpeechAnalyzer` was run on two clips only.

| | sherpa 20M (as shipped) | Apple `SFSpeechRecognizer` | Apple `SpeechAnalyzer` + `.fastResults` |
|---|---|---|---|
| words reached | 99.4% | 100% | 100% |
| lag after word start, median / p90 | 0.66 / 0.87 s | 0.76 / 0.97 s | 0.93 / 1.35 s |
| lag after word end, median / p90 | 0.37 / 0.56 s | 0.47 / 0.66 s | 0.63 / 1.04 s |
| words behind the speaker, median / p90 | 2 / 3 | 2 / 4 | 2 / 4 |
| first word highlighted | 1.01 s | 0.81 s | 1.06 s |
| final transcript word error rate | 21.2% | 8.6% | 6.8% |
| words highlighted before being spoken | 0 | 0 | 0 |

What this says:

- **Apple is clearly more accurate, and no faster.** The tuned sherpa is about 0.1 s quicker in
  steady state. Apple's `SFSpeechRecognizer` lights the first word about 0.2 s sooner and reached
  every word.
- **Against the plan's gate:** word error rate within Apple's plus 3 points fails (21.2% vs 8.6%),
  though part of that gap, roughly 3-4 points by my estimate and not measured exactly, is only
  number formatting: sherpa spells "2024" and "80%" as words, Apple writes digits, and the
  matcher already copes with that. Partial-result latency of 300 ms or less is missed by both.
- **The matcher is not why a competitor feels faster.** A naive "last 5 words, nearest match in a
  short look-ahead" tracker (my own re-implementation of the idea in VoicePrompter's public web
  code, not its native code) has the same lag as ours, reaches only 83% of sherpa's words at a
  look-ahead of 3, and highlights words before they are spoken (17-65 times over six clips).
- **`SpeechAnalyzer` is not suited to word tracking here.** It delivers text in bursts about once a
  second, whether or not `.fastResults`, buffer size or `prepareToAnalyze` are used. Without
  `.fastResults` the first words arrived 3 s late. Its accuracy is the best of the three.
- **Script biasing (`contextualStrings`, on-device) changed nothing measurable** on one clip:
  latency the same, word error rate 7.2% to 6.5% (one word).
- **What is still unexplained is why the competitor feels faster on Android.** The Google
  recognizer on a phone may simply respond sooner than anything measured here, but that is
  unmeasured. It is the main reason to run the Android test.

Integration traps found while building the Apple replay:

1. Apple's text grows within a segment and **restarts from nothing after a long pause** (71 words
   to 1 at a paragraph break), and the last event can be empty. An adapter must treat a drop in
   word count as a new segment. `LiveWordEmitter` silently drops the first words after a shrink,
   which is fine for sherpa and wrong for Apple.
2. Apple writes **digits** ("3 simple ways") where the script may have words ("three").
3. `SFSpeechRecognizer` needs the Speech Recognition permission. A command-line tool is killed with
   no prompt (the permission is attributed to the host app); a small signed `.app` bundle with its
   own `NSSpeechRecognitionUsageDescription` gets the prompt. `SpeechAnalyzer` showed no prompt.
4. Apple's partial text is punctuated and capitalised.

Caveats: one Mac, synthetic voices (clean, regular speech that flatters every engine), six clips,
CPU and battery not measured, no iPhone or iPad, no accents, no noise. Do not read differences under
about 0.1 s as real.

## Benchmark protocol

**Candidates**

- sherpa 20M as shipped (`SherpaSpeechEngine`)
- Apple `SFSpeechRecognizer` forced on-device, and `SpeechAnalyzer` / `SpeechTranscriber` on
  OS 26+ if available (Mac run done; `tools/voice_latency/apple_trace.swift`; still to do on an iPhone)
- Android `SpeechRecognizer.createOnDeviceSpeechRecognizer`, fed our audio through
  `EXTRA_AUDIO_SOURCE` while the camera records
- VoicePrompter, as a black-box reference

**Inputs**

- The synthetic clips from `tools/voice_latency/make_speech.swift` (known word times), at several
  rates, plus **real people**: at least 5 speakers, accents and rooms, on real phones, reading
  10 scripts.
- Play the same clip to every candidate: speaker about 30 cm from the phone, quiet room.

**Measure**

- Time to first highlight; lag after each word starts and ends (median and p90); words behind
  the speaker; word error rate; words never reached; false jumps; CPU and heat over a 10-minute
  take.
- For the black-box reference: screen-record the phone at 60 fps and read the frame at which each
  word is highlighted. Its highlight may be line-level, so compare line changes, not words.

**Things to verify before committing**

- Android: which API level honors `EXTRA_AUDIO_SOURCE`; whether the Google recognizer accepts it;
  concurrent capture with our `AudioRecord`; behavior across a Pixel, a Samsung and a budget
  phone; session auto-end on silence and the restart gap; on-device availability and language
  packs; partial results while the camera is recording.
- Apple: on-device support for en-US on the target OS versions; whether script `contextualStrings`
  still help on-device; how much partial transcripts are revised; task length limits and restarts;
  whether `SpeechAnalyzer` volatile results carry word timings. One developer write-up reports
  `SpeechAnalyzer` has no equivalent of `contextualStrings` as of iOS 26.0.

**Proposed pass criteria** (a judgment, to be confirmed by the owner)

- First highlight within 1 s of the first word.
- Median lag after word end of 0.3 s or less, p90 under 0.6 s.
- Fewer than 1% of words never reached, and no false forward jumps.
- Beats sherpa on real speakers, not only on synthetic voices.

## Decisions made

1. **Privacy: always on-device, never uploaded.** This is a fixed rule, not a preference. A
   platform engine is only usable where it can be forced on-device; everywhere else sherpa runs.
2. **Modes stay Normal, Voice and Audio.** No fourth "sound" mode.

## Still open

1. **Language scope** at launch: English only, or whatever the platform recognizers support?
2. **Engine policy** per platform once the benchmark is in.

## Licensing

VoicePrompter's web app is GPL-3.0. Do not copy its code into EchoPrompt; derived code would have
to be released under the same license. Reading it for ideas is fine.

## Sources

- https://voiceprompter.app/ and https://voiceprompter.app/changelog and https://voiceprompter.app/android
- https://github.com/kosuvorov/VoicePrompter (see `src/speech.ts`, `changelog.md`)
- https://developer.android.com/reference/android/speech/RecognizerIntent (`EXTRA_AUDIO_SOURCE`,
  `EXTRA_BIASING_STRINGS`)
- https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo
  and https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5
  (`SpeechAnalyzer`, secondary sources)
- https://origin-devforums.apple.com/forums/thread/794510 (`audioTimeRange` on volatile results)
- https://developer.apple.com/forums/thread/650927 (2020 report that `contextualStrings` had no
  effect with on-device recognition; may be outdated)
