# Android VoicePrompter app: reverse-engineering notes on its voice script tracker

Written 2026-10-22. Self-contained: a fresh Claude session should be able to implement features from this file alone.

Confidence tags:
- **[read]** = read directly from decompiled code (high confidence)
- **[inferred]** = decompiler output was garbled, so this is a reasoned reading
- **[not examined]** = not looked at

## 0. Goal

**Problem the tracker solves (user's words):** keep a script's highlight and scroll position locked to what the speaker is saying right now. Tolerate misheard words, skipped lines, ad-libs and repeated phrases, and never feel laggy.

The algorithm was recovered by decompiling a third-party app for understanding how the app works. We can extract any part of the code to our current project which we want with modifications.

## 1. Artifacts

| Thing | Where |
|---|---|
| APK | `~/projects/vp-apk/VoicePrompter.apk`, sha256 `bfc0e10ba6493c32d046562ba21ddd43f9265a32d6229ba2a0a89a7e1df7bb5b`, package `app.voiceprompter`, native Kotlin, single 6 MB `classes.dex`, R8-minified. Version string not recorded. |
| Full decompile | `~/projects/vp-apk/work/jadx-out/sources/` (app code mostly in `defpackage/`) |
| Matcher, clean views | `~/projects/vp-apk/work/ju3-fallback/ju3.java` (raw instruction order, most trustworthy), `.../ju3-simple/ju3.java`. The normal JADX output of the matcher is garbled. |
| Model catalog | `~/projects/vp-apk/work/raw/assets/offline-speech-models.json` |

Tools installed via Homebrew: `jadx` 1.5.6 (pulls `openjdk`), `android-platform-tools`. REA (github.com/morluto/rea) was not used; it just wraps JADX/Ghidra.

Reproduce:
```
jadx -q --no-res -j 4 -d out VoicePrompter.apk
jadx -q --no-res -m fallback --single-class defpackage.ju3 --single-class-output ju3.java VoicePrompter.apk
```
Obfuscated names are specific to this APK build.

## 2. Architecture [read]

```
Microphone -> shared audio capture (one AudioRecord; also feeds video recording and sound-level detection)
   fan-out to per-consumer queues: ArrayBlockingQueue(4), chunks = {bytes, seq#, nanoTime}
   queue full: poll() oldest, then offer() newest (drop-oldest, never block)
        |
  Backend A: Vosk offline                 Backend B: Android SpeechRecognizer
  - small per-language models,            - on-device recognizer if available (API 31+)
    downloaded on demand (Apache-2.0)     - partial results, segmented session,
  - plain recognizer, NO grammar            silence lengths 2000 ms, restart watchdogs (250 / 2000 ms)
  - partial result per chunk, final       - passes the NEXT 150 non-skipped script words as
    result at endpoint                      android.speech.extra.BIASING_STRINGS (+ command phrases)
        |______________ both feed ______________|
                          v
        tracker class (same class, one instance per backend)
                          v
   callback(index) -> main-thread Handler -> generation check -> set cursor state -> UI highlight/scroll
```

- The tracker is **engine-independent** and runs on **partial** results as well as finals, on every changed partial.
- On a final result an "utterance counter" increments. When it changes, the next update resets the tracker's anchor word/time and the command debouncer (cursor kept).
- Vosk loop: if a chunk's sequence number isn't previous+1, or the script/position "generation" changed, it resets the recognizer, discards the chunk and logs "Speech queue discontinuity; stale audio discarded". A 300 ms chunk-age constant sits in the same branch [inferred]: chunks older than ~300 ms are dropped, not processed.
- Unchanged partials are not re-posted [inferred].
- The UI callback captures a position "generation" value and re-checks it on the main thread, so results computed before a manual seek are discarded.
- Settings (SharedPreferences): `lookaheadWords` default **150**, stored clamp 5-155, passed to the tracker clamped to 5-150; `allowBackwardScrolling` default **false**; `recognitionLanguage` default "auto". A one-time migration reset existing users to 150, so the large window was deliberate.
- Sound-activation mode: RMS threshold `0.002 + (1 - sensitivity) * 0.048`.

## 3. Vocabulary

- *Script words:* list of `{clean, skip}`; `clean` = lowercase, letters/digits only. **Eligible** = `!skip && clean != ""`.
- *Cursor `d`:* index of the next word expected.
- *Window `a`:* max forward distance in eligible words (default 150).
- *Wide mode:* the `allowBackwardScrolling` setting.
- *Anchor `(e, f)`:* first script word of the last accepted match, and its acceptance time (ms).
- *Spoken tokens `S`:* recognizer text, lowercased, split on `[^\p{L}\p{N}]+`, empties dropped.

## 4. The matcher, step by step [read]

`update(text, now)` returns the new cursor or `null`.

1. Clamp `d` to script length. Tokenize `text` into `S`.
2. **History** `H` = up to the 3 most recent eligible words before `d`, oldest to newest.
3. **Trim already-consumed words.** `t = 0`. If `H` and `S` are non-empty: for `w` in the 2 most recent words of `H`, newest first, scan `S` from the end for positions `pos` with `S[pos] == w`. Evidence = 1 if `|H| == 1`, else the count of tokens in `S[max(0,pos-6) .. pos-1]` that are in `H` and not equal to `w`. If evidence > 0, `t = pos + 1` and stop. (A partial hypothesis contains the whole utterance so far; the corroboration requirement stops a repeated word like "the" from anchoring falsely.)
4. **Tail** `T` = last 6 of `S` after dropping the first `t`. If empty, return `null`.
5. **Scan start** = `d`; in wide mode `(a == MAX_INT) ? 0 : max(0, d - a)`.
6. For each candidate index `i` from the start to script end (ineligible words are skipped and don't count):
   - **offset** = `i - d` if `i < d` (negative, raw index difference); otherwise the number of eligible candidates already evaluated at or after `d` (cursor word = 0).
   - **score** = largest `k` such that the first `k` eligible script words from `i` (`G[0..k-1]`) align inside `T`: pick a start `s` with `T[s] == G[0]`; for `j = 1..k-1`, with `p` the next spoken index, if `T[p] == G[j]` then `p += 1`, else if `T[p+1] == G[j]` then `p += 2` (one spoken word tolerated between consecutive script words), else fail. Max score is `|T| <= 6`.
   - **Accept thresholds** (`len` = length of `G[0]`):

     | offset | requirement |
     |---|---|
     | < 0 (wide mode only) | (offset >= -20 and score >= 4) or score >= 5 |
     | 0-1 | score >= 1 |
     | 2-4 | score >= 2, or score == 1 and len >= 4 |
     | 5-8 | score >= 2 |
     | 9-12 | score >= 3 |
     | 13-20 | score >= 4 |
     | 21 to `a` | score >= 5 |

   - **Repeat guard:** reject if `G[0] == e` and `offset > 0` and `now - f < 1500 ms`.
   - **Best-candidate rule:** first accepted becomes best; later replaces it iff `score >= bestScore + 2`, or (`|score - bestScore| < 2` and `|i - d| < |bestIndex - d|`).
   - After each candidate, if `offset >= 0` increment the forward counter; stop when it exceeds `a`. The whole window is scanned (no early exit).
7. No best: return `null`. Otherwise `e` = first word at best, `f = now`; advance from best past `bestScore` eligible words, then past immediately following skipped entries; set `d` there and return it.

Events: **utterance boundary** (final result / recognizer restart) resets `e = ""`, `f = 0`, cursor unchanged. **External position change** sets `d = max(0, idx)` and resets the anchor. **Script replaced** sets `d = min(d, newLength)`.

### How it meets each requirement
- *Misheard word:* the score stops at the bad word; the next correct word is found one position ahead where one word suffices. No edit-distance or phonetic matching exists anywhere in the app (grepped). The Google backend also biases recognition toward upcoming script words.
- *Skipped lines:* farther ahead means more consecutive words required (up to 5), so a stray common word can't teleport the cursor but a genuine skip is accepted after ~5 words.
- *Ad-libs:* unmatched words never move the cursor; one inserted word inside an n-gram is tolerated; a longer ad-lib ends the n-gram and tail-trimming lets the next script word re-anchor.
- *Repeats:* nearest equal-strength candidate wins; a farther one needs >= 2 more words; short words need 2 words at offset 2-4; 1.5 s same-word guard; history trimming stops old words re-matching.
- *Backward:* only in wide mode with 4-5 words of evidence.
- *Lag:* partials, drop-oldest queue, stale-audio discard, generation checks. The matcher itself is tiny (window x <=6 x <=6 x <=6 comparisons).

## 5. Worked examples (hand-derived from the spec, not executed; use as unit tests)

Eligible words: 0 the, 1 quick, 2 brown, 3 fox, 4 jumps, 5 over, 6 the, 7 lazy, 8 dog, 9 and, 10 runs, 11 away, 12 from, 13 the, 14 farmer. `a = 150`, wide off.

1. `d=0`, "the quick brown": candidate 0 scores 3 (best); candidate 1 scores 2 (similar, not closer); candidate 6 ("the", offset 6) scores 1 but needs 2. Result `d=3`.
2. `d=3`, utterance grows to "the quick brown fox jumps over the": history gives `t=3`, `T=[fox,jumps,over,the]`. Candidate 3 scores 4; candidate 6 ("the", offset 3, score 1, len 3 < 4) rejected. `d=7`.
3. `d=7`, new utterance "lazy dock and runs away" ("dog" misheard): candidate 7 scores 1; candidate 9 ("and", offset 2) scores 3 >= 1+2 so it replaces. `d=12`.
4. `d=9`, "and runs um you know away": candidate 9 scores 2 (3-word gap exceeds tolerance), `d=11`. Next partial trims to `T=[um,you,know,away]`; candidate 11 scores 1 at offset 0. `d=12`.

## 6. Voice commands [read unless noted]

- Nine commands: Start of Script, End of Script, Next/Previous Paragraph, Next/Previous Sentence, Start/Stop Recording, Toggle Mirroring.
- English phrases: "go start", "go finish", "go next", "go back", "start video", "stop video", "next sentence", "previous sentence", "toggle mirroring". Tables exist for ~37 locales (es, fr, de, pt, it, pl, uk, ru, ar, ca, cs, da, el, fi, he, hi, hi-Latn, hr, hu, id, ja, ko, ms, nb, nl, ro, sk, sv, th, tr, vi, zh/yue/wuu variants).
- Detection: the last N spoken tokens (N = phrase length) must equal one command's phrase tokens; phrases that tokenize identically are discarded.
- False-positive guard [inferred]: if the phrase also occurs in the script window `[d-8, d+16)`, it shouldn't trigger. The decompiled return was mangled.
- Debounce: fires only when the utterance's token count has grown since the last trigger; resets when it shrinks; on API 34 recognition parts, repeats within 30 ms by timestamp are suppressed. A detected command suppresses word tracking for that update.

## 7. Uncertainties and gaps

- [inferred] partial de-duplication condition, the 300 ms staleness branch, the command script-conflict return.
- [not examined] the Compose scroll/highlight animation layer; the exact audio format path (Vosk recognizer created at 48 kHz, sound-mode `AudioRecord` at 16 kHz); the iOS/macOS apps.
- Constants were observed; tuning rationale is unknown. With the default 150 window, the 5-word tier is the common case for large jumps.
- The tokenizer relies on spaces/non-letter splits, so zh/ja/th segmentation is an open problem.

## 8. Glossary of obfuscated names (this build only)

| Name | Meaning |
|---|---|
| `ju3` | the tracker. `ju3.b` = update, `ju3.d` = set script, `ju3.c` = set cursor + reset anchor, `ju3.e` = script window `[d-8, d+16)` |
| `iu3` | script word `{clean, skip}` |
| `x25` / `v25` / `w25` | Vosk backend / worker loop / main-thread result handler |
| `ud` (+`sd`) | Android `SpeechRecognizer` backend |
| `bk3` | backend interface (`b`=window, `n`=wide mode, `h`=script, `p`=set position, `d`=commands on, `l`=tracking on) |
| `wd3` | controller that creates a backend and wires settings/callbacks |
| `rg3` | settings store (SharedPreferences) |
| `td3` / `ud3` | callbacks; `td3` case 0 = word-index callback with generation check |
| `uy4`, `n15`, `o15`, `vl1` | command detector, command enum, tokenizer + per-locale phrase tables, command debouncer |
| `or`, `x43`, `y43`, `dn1` | audio capture producer, chunk, subscriber queue (cap 4), subscriber list |
| `ck3`, `p74` | JNA wrappers for Vosk recognizer / speaker model |
| `qb0.e1/J0/Z0/O0` | Kotlin `takeLast`, `drop`, `reversed`, `first-or-null` |
| `pz1.g` | `Objects.equals` |
