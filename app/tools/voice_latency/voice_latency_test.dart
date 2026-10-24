// Voice-mode latency harness: replays speech through the pipeline the record screen uses
// (external mic samples -> SherpaSpeechEngine -> VoiceMatcher -> PrompterController) in real
// time and times every highlight change against known word times. A second test replays the
// bare recogniser in virtual time to show where the delay comes from.
//
// 1. Make clips (macOS voices; writes NAME.wav, 16 kHz mono, and NAME.json with word times):
//      swiftc -O tools/voice_latency/make_speech.swift -o /tmp/make_speech
//      /tmp/make_speech tools/voice_latency/sample_script.txt samantha 0.50 1.0 /tmp/clips/a_sam 1.0
//    args: script, voice name, rate 0..1, silence before speech (s), output prefix, paragraph gap (s)
// 2. Run (from app/):
//      VL_DIR=/tmp/clips VL_SCRIPT=tools/voice_latency/sample_script.txt \
//        flutter test tools/voice_latency/voice_latency_test.dart --reporter expanded
//    VL_CLIPS=a,b   only these clips (repeat a name to see cold then warm)
//    VL_OUT=f.json  write the end-to-end summary, with per-word timings
//    VL_NOISE=-55   add a noise floor in dBFS (real microphones are never digitally silent)
//    VL_IDLE=1.5    seconds between opening the record screen and pressing Start
//    VL_WARM=0      skip RecordScreen's model warm-up (reproduces the old cold start)
//    VL_BLANK=0,3   blank penalties to compare in the virtual-time test; VL_ENDPOINT=0 turns endpoints off
//    VL_MODELS=...  compare other streaming transducers (see _ModelSpec); VL_VERBOSE=1 prints raw hypotheses
//    VL_APPLE=dir   traces from apple_trace.swift: compares Apple's recogniser with sherpa (test "Apple traces")
//    VL_REREAD=a,b  clips where the speaker repeats a passage: prints how the highlight moves (backward jumps)
// Run one test with --plain-name "end to end" or --plain-name "stage breakdown".
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:echoprompter/core/matching/audio_aligner.dart';
import 'package:echoprompter/core/matching/voice_matcher.dart';
import 'package:echoprompter/core/script/text.dart';
import 'package:echoprompter/core/settings/prompt_settings.dart';
import 'package:echoprompter/features/prompter/prompter_controller.dart';
import 'package:echoprompter/services/audio/audio_input.dart';
import 'package:echoprompter/services/speech/sherpa_speech_engine.dart';
import 'package:echoprompter/services/speech/speech_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _chunkSamples = 320; // 20 ms at 16 kHz, like the native capture buffers
const _chunkMicros = 20000;

/// A streaming transducer to evaluate. VL_MODELS="label|encoder|decoder|joiner|tokens[|modelType];..."
/// (absolute paths); without it the model the app ships is used.
class _ModelSpec {
  _ModelSpec(this.label, this.encoder, this.decoder, this.joiner, this.tokens, [this.modelType = '']);
  final String label, encoder, decoder, joiner, tokens, modelType;
}

List<_ModelSpec> _models(String shippedDir) {
  final env = Platform.environment['VL_MODELS'];
  if (env == null) {
    final d = p.join(shippedDir, 'online');
    return [_ModelSpec('shipped 20M', p.join(d, 'encoder.int8.onnx'), p.join(d, 'decoder.onnx'), p.join(d, 'joiner.int8.onnx'), p.join(d, 'tokens.txt'))];
  }
  return [
    for (final m in env.split(';'))
      _ModelSpec(m.split('|')[0], m.split('|')[1], m.split('|')[2], m.split('|')[3], m.split('|')[4], m.split('|').length > 5 ? m.split('|')[5] : ''),
  ];
}

/// Endpoint settings to compare. The recogniser is reset at every endpoint.
const _endpointConfigs = [
  (label: 'endpoints 1.0/0.6', endpoint: true, rule1: 1.0, rule2: 0.6),
];

class _Word {
  _Word(this.text, this.start, this.end);
  final String text;
  final double start, end;
}

class _Clip {
  _Clip(this.name, this.samples, this.words);
  final String name;
  final Float32List samples;
  final List<_Word> words;
  double get seconds => samples.length / 16000;
}

/// Adds a steady noise floor ([dbfs] RMS, e.g. -55) so silences are not digital zeros,
/// which no real microphone produces. Deterministic.
Float32List _withNoise(Float32List x, double dbfs) {
  final amp = math.pow(10, dbfs / 20).toDouble();
  final r = math.Random(7);
  final out = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    // sum of 4 uniforms ~ gaussian, unit variance after scaling
    final g = (r.nextDouble() + r.nextDouble() + r.nextDouble() + r.nextDouble() - 2) * math.sqrt(3);
    out[i] = (x[i] + g * amp).clamp(-1.0, 1.0).toDouble();
  }
  return out;
}

_Clip _loadClip(String dir, String name) {
  final wav = File(p.join(dir, '$name.wav')).readAsBytesSync();
  final data = ByteData.sublistView(wav, 44);
  final samples = Float32List(data.lengthInBytes ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  final j = jsonDecode(File(p.join(dir, '$name.json')).readAsStringSync()) as Map<String, dynamic>;
  final words = [
    for (final w in j['words'] as List) _Word(w['w'] as String, (w['s'] as num).toDouble(), (w['e'] as num).toDouble()),
  ];
  final noise = double.tryParse(Platform.environment['VL_NOISE'] ?? '');
  return _Clip(noise == null ? name : '$name @${noise.toStringAsFixed(0)}dBFS', noise == null ? samples : _withNoise(samples, noise), words);
}

/// A live microphone: audio exists in real time, a subscriber only receives what is
/// recorded after it attaches, and a chunk that is late (busy isolate) arrives in a burst.
class _LiveMic {
  _LiveMic(this.samples, this.clock);
  final Float32List samples;
  final Stopwatch clock;
  Duration? subscribedAt;

  Stream<Float32List> stream() async* {
    subscribedAt = clock.elapsed;
    var k = clock.elapsedMicroseconds ~/ _chunkMicros + 1;
    while ((k + 1) * _chunkSamples <= samples.length) {
      final wait = (k + 1) * _chunkMicros - clock.elapsedMicroseconds;
      if (wait > 0) await Future<void>.delayed(Duration(microseconds: wait));
      yield Float32List.sublistView(samples, k * _chunkSamples, (k + 1) * _chunkSamples);
      k++;
    }
  }
}

/// The prompter only reads this when no external samples are given.
class _NoInput implements AudioInput {
  @override
  Future<bool> hasPermission() async => false;
  @override
  Stream<Float32List> start() => const Stream.empty();
  @override
  Future<void> stop() async {}
}

/// Logs what the engine emits and when, to see the start of a take.
class _TimingEngine implements SpeechEngine {
  _TimingEngine(this.inner, this.clock, this.log);
  final SpeechEngine inner;
  final Stopwatch clock;
  final List<String> log;
  @override
  Future<void> init() => inner.init();
  @override
  Stream<List<String>> listen(Stream<Float32List> samples) =>
      inner.listen(samples).map((w) {
        log.add('${(clock.elapsedMicroseconds / 1e6).toStringAsFixed(2)}s emitted ${w.join(' ')}');
        return w;
      });
  @override
  Future<List<TranscriptSegment>> transcribeFile(String path) => inner.transcribeFile(path);
  @override
  Future<void> dispose() => inner.dispose();
}

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

double _pct(List<double> sorted, double q) =>
    sorted.isEmpty ? double.nan : sorted[math.min(sorted.length - 1, (q * (sorted.length - 1)).round())];

/// Words the speaker is ahead of the highlight, sampled every 50 ms while speaking.
/// [at] is when each word first became highlighted (null: never).
List<double> _wordsBehind(_Clip clip, List<double?> at) {
  final out = <double>[];
  var shown = -1;
  for (var t = clip.words.first.start; t <= clip.words.last.end; t += 0.05) {
    var spoken = -1;
    for (var k = 0; k < clip.words.length; k++) {
      if (clip.words[k].start <= t) spoken = k;
    }
    while (shown + 1 < at.length && at[shown + 1] != null && at[shown + 1]! <= t) {
      shown++;
    }
    out.add((spoken - shown).toDouble());
  }
  return out..sort();
}

String _s(double v) => v.isNaN ? '  n/a' : '${v.toStringAsFixed(2)}s';

/// Times the first highlight for every script word and prints the summary.
class _Result {
  _Result(this.clip, this.reachedAt, this.micOpenAt, this.updates);
  final _Clip clip;

  /// Seconds after Start at which word i first became highlighted (null: never).
  final List<double?> reachedAt;
  final double micOpenAt;
  final List<(double, int)> updates;

  List<double> _lags(double Function(_Word) ref) {
    final out = <double>[];
    for (var i = 0; i < clip.words.length; i++) {
      final t = reachedAt[i];
      if (t != null) out.add(t - ref(clip.words[i]));
    }
    return out..sort();
  }

  Map<String, Object?> summary() {
    final end = _lags((w) => w.end), start = _lags((w) => w.start);
    final ahead = _wordsBehind(clip, reachedAt);
    final premature = [
      for (var i = 0; i < clip.words.length; i++)
        if (reachedAt[i] != null && reachedAt[i]! < clip.words[i].start) i,
    ];
    final reached = reachedAt.where((t) => t != null).length;
    return {
      'clip': clip.name,
      'words': clip.words.length,
      'reached': reached,
      'mic_open_s': micOpenAt,
      'first_highlight_after_first_word_start_s': reachedAt.first == null ? null : reachedAt.first! - clip.words.first.start,
      'lag_vs_end_median_s': _pct(end, .5),
      'lag_vs_end_p90_s': _pct(end, .9),
      'lag_vs_start_median_s': _pct(start, .5),
      'lag_vs_start_p90_s': _pct(start, .9),
      'lag_vs_start_max_s': start.isEmpty ? null : start.last,
      'words_behind_median': _pct(ahead, .5),
      'words_behind_p90': _pct(ahead, .9),
      'words_behind_max': ahead.last,
      'premature_words': premature.length,
      'per_word': [
        for (var i = 0; i < clip.words.length; i++)
          {'w': clip.words[i].text, 's': clip.words[i].start, 'e': clip.words[i].end, 'shown': reachedAt[i]},
      ],
    };
  }

  void print_() {
    final s = summary();
    // ignore: avoid_print
    print('''
--- ${clip.name}  (${clip.words.length} words, reached ${s['reached']}) ---
  mic stream opened            ${_s(micOpenAt)} after Start (speech begins ${_s(clip.words.first.start)})
  first word highlighted       ${_s(s['first_highlight_after_first_word_start_s'] as double? ?? double.nan)} after it was first spoken
  lag vs word END    median ${_s(s['lag_vs_end_median_s'] as double)}   p90 ${_s(s['lag_vs_end_p90_s'] as double)}
  lag vs word START  median ${_s(s['lag_vs_start_median_s'] as double)}   p90 ${_s(s['lag_vs_start_p90_s'] as double)}   max ${_s(s['lag_vs_start_max_s'] as double? ?? double.nan)}
  words behind the speaker   median ${(s['words_behind_median'] as double).toStringAsFixed(0)}   p90 ${(s['words_behind_p90'] as double).toStringAsFixed(0)}   max ${(s['words_behind_max'] as double).toStringAsFixed(0)}
  highlighted before spoken  ${s['premature_words']}''');
    final b = StringBuffer('  first words (spoken start -> highlighted):\n');
    for (var i = 0; i < math.min(12, clip.words.length); i++) {
      final t = reachedAt[i];
      b.writeln('    ${clip.words[i].text.padRight(12)} ${clip.words[i].start.toStringAsFixed(2).padLeft(6)}s -> ${t == null ? 'never' : '${t.toStringAsFixed(2)}s (+${(t - clip.words[i].start).toStringAsFixed(2)})'}');
    }
    // ignore: avoid_print
    print(b);
  }
}

Future<_Result> _runEndToEnd(_Clip clip, String script, SpeechEngine engine, {List<String>? emissionLog, Stopwatch? sharedClock}) async {
  final clock = sharedClock ?? Stopwatch();
  final c = ProviderContainer(overrides: [
    speechEngineProvider.overrideWithValue(emissionLog == null ? engine : _TimingEngine(engine, clock, emissionLog)),
    audioInputProvider.overrideWithValue(_NoInput()),
  ]);
  final ctl = c.read(prompterProvider.notifier);
  final mic = _LiveMic(clip.samples, clock);
  final updates = <(double, int)>[];
  var last = -1;
  c.listen(prompterProvider, (_, s) {
    final i = s.progress.confirmedWordIndex;
    if (i != last) {
      last = i;
      updates.add((clock.elapsedMicroseconds / 1e6, i));
    }
  });
  // RecordScreen warms the model up when it opens (VL_WARM=0 reproduces the old behaviour).
  if (Platform.environment['VL_WARM'] != '0') ctl.warmUpVoice();
  await ctl.begin(sessionId: 1, script: script, mode: PromptControlMode.voice, externalSamples: mic.stream());
  // Time between opening the record screen and pressing Start (countdown included).
  final idle = double.tryParse(Platform.environment['VL_IDLE'] ?? '0') ?? 0;
  if (idle > 0) await Future<void>.delayed(Duration(milliseconds: (idle * 1000).round()));
  clock.start(); // the take starts: RecordScreen calls play() right after startRecording
  await ctl.play();
  final remaining = Duration(milliseconds: (clip.seconds * 1000).round() + 500) - clock.elapsed;
  if (remaining > Duration.zero) await Future<void>.delayed(remaining);
  await ctl.pause();
  c.dispose();
  final reachedAt = List<double?>.filled(clip.words.length, null);
  for (final (t, idx) in updates) {
    for (var i = 0; i <= math.min(idx, clip.words.length - 1); i++) {
      reachedAt[i] ??= t;
    }
  }
  return _Result(clip, reachedAt, (mic.subscribedAt ?? Duration.zero).inMicroseconds / 1e6, updates);
}

// --- stage breakdown in virtual time (no compute, no pacing) ----------------------------

/// What the recogniser's hypothesis looked like after each 20 ms of audio.
class _Trace {
  final times = <double>[];
  final texts = <String>[];
  final endpoints = <bool>[];
  double computeSeconds = 0;
}

_Trace _trace(_ModelSpec spec, Float32List samples, {bool endpoint = true, double rule1 = 1.0, double rule2 = 0.6, double blankPenalty = 0}) {
  final rec = sherpa.OnlineRecognizer(
    sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(encoder: spec.encoder, decoder: spec.decoder, joiner: spec.joiner),
        tokens: spec.tokens,
        modelType: spec.modelType,
        numThreads: 2,
      ),
      blankPenalty: blankPenalty,
      enableEndpoint: endpoint,
      rule1MinTrailingSilence: rule1,
      rule2MinTrailingSilence: rule2,
    ),
  );
  final stream = rec.createStream();
  final t = _Trace();
  final compute = Stopwatch()..start();
  for (var k = 0; (k + 1) * _chunkSamples <= samples.length; k++) {
    stream.acceptWaveform(samples: Float32List.sublistView(samples, k * _chunkSamples, (k + 1) * _chunkSamples), sampleRate: 16000);
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    t.times.add((k + 1) * _chunkMicros / 1e6);
    t.texts.add(rec.getResult(stream).text);
    final end = endpoint && rec.isEndpoint(stream);
    t.endpoints.add(end);
    if (end) rec.reset(stream);
  }
  t.computeSeconds = compute.elapsedMicroseconds / 1e6;
  stream.free();
  rec.free();
  return t;
}

/// The policy the app shipped before: the newest word is held back until the next word starts,
/// or the hypothesis has not changed for [settleSeconds]. Frozen here for before/after runs.
class _HoldBackEmitter {
  static const settleSeconds = 0.4;
  var _emitted = 0;
  var _last = '';
  var _unchanged = 0.0;

  List<String> update(String hypothesis, double seconds) {
    final words = spokenWords(hypothesis);
    _unchanged = hypothesis == _last ? _unchanged + seconds : 0;
    _last = hypothesis;
    if (words.length < _emitted) _emitted = words.length;
    final stable = _unchanged >= settleSeconds ? words.length : words.length - 1;
    if (stable <= _emitted) return const [];
    final fresh = words.sublist(_emitted, stable);
    _emitted = stable;
    return fresh;
  }

  List<String> flush() {
    final words = spokenWords(_last);
    final fresh = _emitted < words.length ? words.sublist(_emitted) : const <String>[];
    _emitted = 0;
    _last = '';
    _unchanged = 0;
    return fresh;
  }
}

/// Word error rate of [hyp] against [ref] after the matcher's own normalisation (digits are not
/// converted to words, so "three" against "3" counts as an error).
double _wer(List<String> ref, String hyp) {
  final r = [for (final w in ref) normalizeWord(w)].where((w) => w.isNotEmpty).toList();
  final h = spokenWords(hyp);
  final d = List.generate(r.length + 1, (i) => List<int>.filled(h.length + 1, 0));
  for (var i = 0; i <= r.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= h.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= r.length; i++) {
    for (var j = 1; j <= h.length; j++) {
      d[i][j] = math.min(math.min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1));
    }
  }
  return d[r.length][h.length] / r.length;
}

/// A trace from Apple's recogniser (apple_trace tool): one entry per hypothesis, at its arrival time.
/// Apple's text grows within a segment and starts again from nothing after a long pause, so a drop in
/// word count marks the end of a segment (the entry before it is flagged as an endpoint).
_Trace _appleTrace(String path) {
  final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final t = _Trace();
  var prev = 0;
  for (final e in j['events'] as List) {
    final text = e['text'] as String;
    final n = spokenWords(text).length;
    if (t.endpoints.isNotEmpty && n + 1 < prev) t.endpoints[t.endpoints.length - 1] = true;
    prev = n;
    t.times.add((e['t'] as num).toDouble());
    t.texts.add(text);
    t.endpoints.add(false);
  }
  return t;
}

/// Everything recognised: the last hypothesis of each segment, joined.
String _transcript(_Trace t) {
  final parts = <String>[];
  for (var i = 0; i < t.texts.length; i++) {
    final segmentEnds = t.endpoints[i] || i == t.texts.length - 1;
    if (segmentEnds) {
      // the final event can be empty; fall back to the last non-empty text of the segment
      var k = i;
      while (k > 0 && t.texts[k].trim().isEmpty && !t.endpoints[k - 1]) {
        k--;
      }
      parts.add(t.texts[k]);
    }
  }
  return parts.join(' ');
}

/// A deliberately naive tracker, for comparison only: on every hypothesis update, take the last
/// five spoken words and advance to the nearest script word within [lookahead] words that is among
/// them (never the same word twice in a row). It reacts to partial words at once but can be fooled
/// by common words; the app's matcher is the conservative one.
List<double?> _replayNaive(_Trace trace, String script, int nWords, int lookahead) {
  final words = [for (final w in scriptWords(script)) normalizeWord(w)];
  final at = List<double?>.filled(nWords, null);
  var index = 0; // next word to be read
  var last = '';
  for (var i = 0; i < trace.times.length; i++) {
    final spoken = spokenWords(trace.texts[i]);
    final tail = spoken.length > 5 ? spoken.sublist(spoken.length - 5) : spoken;
    if (tail.isEmpty || index >= words.length) continue;
    final set = tail.toSet();
    var checked = 0;
    for (var p = index; p < words.length && checked < lookahead; p++, checked++) {
      if (!set.contains(words[p])) continue;
      if (words[p] == last && checked > 0) continue;
      last = words[p];
      for (var w = index; w <= p && w < nWords; w++) {
        at[w] ??= trace.times[i];
      }
      index = p + 1;
      break;
    }
  }
  return at;
}

/// Replays [trace] through an emission policy and the real matcher; returns the audio
/// time at which each script word became highlighted.
List<double?> _replay(_Trace trace, String script, int nWords, {required List<String> Function(String hyp, double dt) update, required List<String> Function() flush}) {
  final matcher = VoiceMatcher(script);
  var cur = -1;
  final at = List<double?>.filled(nWords, null);
  for (var i = 0; i < trace.times.length; i++) {
    final fresh = update(trace.texts[i], _chunkMicros / 1e6);
    final out = [...fresh, if (trace.endpoints[i]) ...flush()];
    if (out.isEmpty) continue;
    final next = matcher.follow(out, cur);
    if (next != cur) {
      for (var w = cur + 1; w <= next && w < nWords; w++) {
        at[w] = trace.times[i];
      }
      cur = next;
    }
  }
  return at;
}

/// Lags pooled over every clip, per label, for the summary at the end.
final _spurious = <String, int>{};
final _pool = <String, ({List<double> end, List<double> start, List<double> behind, List<double> first, int reached, int total, int early})>{};

void _report(String label, _Clip clip, List<double?> at) {
  List<double> lags(double Function(_Word) ref) =>
      [for (var i = 0; i < clip.words.length; i++) if (at[i] != null) at[i]! - ref(clip.words[i])]..sort();
  final end = lags((w) => w.end), start = lags((w) => w.start);
  final reached = at.where((t) => t != null).length;
  final premature = [for (var i = 0; i < clip.words.length; i++) if (at[i] != null && at[i]! < clip.words[i].start) i].length;
  final pooled = _pool[label];
  final behind = _wordsBehind(clip, at);
  _pool[label] = (
    end: [...?pooled?.end, ...end],
    start: [...?pooled?.start, ...start],
    behind: [...?pooled?.behind, ...behind],
    first: [...?pooled?.first, if (at.first != null) at.first! - clip.words.first.start],
    reached: (pooled?.reached ?? 0) + reached,
    total: (pooled?.total ?? 0) + clip.words.length,
    early: (pooled?.early ?? 0) + premature,
  );
  // ignore: avoid_print
  print('  ${label.padRight(60)} reached ${reached.toString().padLeft(3)}/${clip.words.length}  first word ${at.first == null ? 'never' : _s(at.first! - clip.words.first.start)}  vs START med ${_s(_pct(start, .5))} p90 ${_s(_pct(start, .9))}  words behind med ${_pct(behind, .5).toStringAsFixed(0)} p90 ${_pct(behind, .9).toStringAsFixed(0)}  early $premature');
}

void _printPool() {
  if (_spurious.isNotEmpty) {
    // ignore: avoid_print
    print('\nwords invented in the silence before the speaker starts (summed over clips): $_spurious');
  }
  // ignore: avoid_print
  print('\n=== pooled over ${_pool.values.first.total ~/ 139} clips ===  (lag = seconds after the word was SPOKEN; first = first word of the take)');
  for (final e in _pool.entries) {
    final v = e.value..end.sort()..start.sort()..behind.sort()..first.sort();
    // ignore: avoid_print
    print('  ${e.key.padRight(60)} reached ${(100 * v.reached / v.total).toStringAsFixed(1).padLeft(5)}%  '
        'lag(start) med ${_s(_pct(v.start, .5))} p90 ${_s(_pct(v.start, .9))}  lag(end) med ${_s(_pct(v.end, .5))} p90 ${_s(_pct(v.end, .9))}  '
        'words behind med ${_pct(v.behind, .5).toStringAsFixed(0)} p90 ${_pct(v.behind, .9).toStringAsFixed(0)} max ${v.behind.last.toStringAsFixed(0)}  '
        'first word med ${_s(_pct(v.first, .5))} max ${_s(v.first.isEmpty ? double.nan : v.first.last)}  early ${v.early}');
  }
}

void main() {
  final dir = Platform.environment['VL_DIR'];
  final scriptPath = Platform.environment['VL_SCRIPT'];
  if (dir == null || scriptPath == null) {
    test('voice latency', () {}, skip: 'set VL_DIR and VL_SCRIPT (see the header of this file)');
    return;
  }
  final script = File(scriptPath).readAsStringSync();
  final names = Platform.environment['VL_CLIPS']?.split(',') ??
      (Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.wav')).map((f) => p.basenameWithoutExtension(f.path)).toList()..sort());
  final modelDir = p.join(Directory.current.path, 'assets', 'models', 'en');
  final reports = <Map<String, Object?>>[];

  setUpAll(() async {
    // A host test has no app bundle to find the native library in: load it from the package.
    final config = jsonDecode(File(p.join('.dart_tool', 'package_config.json')).readAsStringSync()) as Map<String, dynamic>;
    final root = (config['packages'] as List).firstWhere((e) => e['name'] == 'sherpa_onnx_macos')['rootUri'] as String;
    sherpa.initBindings(p.join(Uri.parse(root).toFilePath(), 'macos'));
    final support = Directory.systemTemp.createTempSync('vl_support');
    Link(p.join(support.path, 'models', 'en')).createSync(modelDir, recursive: true);
    PathProviderPlatform.instance = _FakePaths(support.path);
  });

  test('end to end through PrompterController (cold start first, then warm)', () async {
    // One engine for the whole run: the first clip pays the model load, like the first
    // Start after launching the app; later clips reuse the loaded recogniser.
    final engine = SherpaSpeechEngine();
    for (final n in names) {
      final log = <String>[];
      final r = await _runEndToEnd(_loadClip(dir, n), script, engine, emissionLog: Platform.environment['VL_VERBOSE'] == null ? null : log);
      r.print_();
      if (log.isNotEmpty) {
        // ignore: avoid_print
        print('  engine emissions (first 12):\n    ${log.take(12).join('\n    ')}');
        // ignore: avoid_print
        print('  highlight updates (first 12): ${r.updates.take(12).map((u) => '${u.$1.toStringAsFixed(2)}s->${u.$2}').join('  ')}');
      }
      reports.add(r.summary());
    }
    await engine.dispose();
    final out = Platform.environment['VL_OUT'];
    if (out != null) File(out).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(reports));
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('re-read trajectory (backward re-anchoring)', () async {
    // VL_REREAD=clip,... : clips where the speaker repeats a passage that VL_SCRIPT only has once.
    // Prints how the highlight moves; there is no ground truth, so read it by eye.
    sherpa.initBindings();
    for (final n in Platform.environment['VL_REREAD']!.split(',')) {
      final clip = _loadClip(dir, n);
      final tr = _trace(_models(modelDir).first, clip.samples, blankPenalty: 3);
      final matcher = VoiceMatcher(script);
      final emitter = LiveWordEmitter();
      final words = scriptWords(script);
      var cur = -1;
      final b = StringBuffer('\n${clip.name}: highlight moves (audio time -> script word)\n');
      for (var i = 0; i < tr.times.length; i++) {
        final fresh = emitter.update(tr.texts[i]);
        if (tr.endpoints[i]) emitter.reset();
        if (fresh.isEmpty) continue;
        final next = matcher.follow(fresh, cur);
        if (next != cur) {
          b.writeln('  ${tr.times[i].toStringAsFixed(2).padLeft(6)}s  #$next ${words[next]}${next < cur ? '   <-- moved BACK from #$cur' : ''}');
          cur = next;
        }
      }
      // ignore: avoid_print
      print(b);
    }
  }, skip: Platform.environment['VL_REREAD'] == null ? 'set VL_REREAD' : null, timeout: const Timeout(Duration(minutes: 10)));

  test('Apple traces vs sherpa (same clips, same matcher)', () async {
    // VL_APPLE=<dir of NAME.<kind>.json written by apple_trace>; kinds: sf, analyzer.
    sherpa.initBindings();
    final applDir = Platform.environment['VL_APPLE']!;
    final wers = <String, List<double>>{};
    for (final n in names) {
      final clip = _loadClip(dir, n);
      final base = n;
      // sherpa as shipped (blank penalty 3, endpoints off so the hypothesis accumulates for WER)
      final ref = _trace(_models(modelDir).first, clip.samples, endpoint: false, blankPenalty: 3);
      wers.putIfAbsent('sherpa 20M', () => []).add(_wer([for (final w in clip.words) w.text], ref.texts.last));
      final tr = _trace(_models(modelDir).first, clip.samples, blankPenalty: 3);
      final live = LiveWordEmitter();
      // ignore: avoid_print
      print('\n${clip.name}');
      _report('sherpa 20M | LiveWordEmitter', clip, _replay(tr, script, clip.words.length, update: (h, _) => live.update(h), flush: () {
        live.reset();
        return const [];
      }));
      for (final la in [3, 5]) {
        _report('sherpa 20M | naive tracker, lookahead $la', clip, _replayNaive(tr, script, clip.words.length, la));
      }
      for (final kind in ['sf', 'analyzer']) {
        final file = File(p.join(applDir, '$base.$kind.json'));
        if (!file.existsSync()) continue;
        final at = _appleTrace(file.path);
        final label = kind == 'sf' ? 'Apple SFSpeechRecognizer (on-device)' : 'Apple SpeechAnalyzer (fastResults)';
        final em = LiveWordEmitter();
        _report('$label | LiveWordEmitter', clip, _replay(at, script, clip.words.length, update: (h, _) => em.update(h), flush: () {
          em.reset();
          return const [];
        }));
        wers.putIfAbsent(label, () => []).add(_wer([for (final w in clip.words) w.text], _transcript(at)));
        for (final la in [3, 5]) {
          _report('$label | naive tracker, lookahead $la', clip, _replayNaive(at, script, clip.words.length, la));
        }
      }
    }
    _printPool();
    for (final e in wers.entries) {
      final v = e.value..sort();
      // ignore: avoid_print
      print('final-transcript WER ${e.key.padRight(40)} mean ${(100 * v.reduce((a, b) => a + b) / v.length).toStringAsFixed(1)}%  worst ${(100 * v.last).toStringAsFixed(1)}%  (${v.length} clips)');
    }
  }, skip: Platform.environment['VL_APPLE'] == null ? 'set VL_APPLE' : null, timeout: const Timeout(Duration(minutes: 15)));

  test('stage breakdown in virtual time (model limit vs emission policy)', () async {
    // ignore: avoid_print
    print('\n=== where the delay comes from (audio time only; real runs add decode compute) ===');
    final models = _models(modelDir);
    final rtf = <String, List<double>>{};
    for (final n in names) {
      final clip = _loadClip(dir, n);
      // ignore: avoid_print
      print('\n${clip.name}');
      for (final m in models) {
        for (final bp in (Platform.environment['VL_BLANK'] ?? '0').split(',').map(double.parse)) {
          final noEndpoints = Platform.environment['VL_ENDPOINT'] == '0';
          final cfg = (label: '${noEndpoints ? 'endpoints off' : _endpointConfigs.first.label}${bp == 0 ? '' : ' blank-$bp'}', endpoint: !noEndpoints, rule1: 1.0, rule2: 0.6);
          final tr = _trace(m, clip.samples, endpoint: cfg.endpoint, rule1: cfg.rule1, rule2: cfg.rule2, blankPenalty: bp);
          rtf.putIfAbsent(m.label, () => []).add(tr.computeSeconds / clip.seconds);
          if (Platform.environment['VL_VERBOSE'] != null) {
            var prev = '';
            final b = StringBuffer('  ${m.label} / ${cfg.label} - hypothesis changes (first 4.5 s of audio):\n');
            for (var i = 0; i < tr.times.length && tr.times[i] < 4.5; i++) {
              if (tr.texts[i] != prev || tr.endpoints[i]) b.writeln('    ${tr.times[i].toStringAsFixed(2)}s  "${tr.texts[i]}"${tr.endpoints[i] ? '   <endpoint>' : ''}');
              prev = tr.texts[i];
            }
            // ignore: avoid_print
            print(b);
          }
          // Words the recogniser invents during the silence before the speaker starts, plus
          // any hypothesis text that appears before the first word is actually spoken.
          var invented = 0;
          for (var i = 0; i < tr.times.length && tr.times[i] < clip.words.first.start - 0.05; i++) {
            invented = math.max(invented, spokenWords(tr.texts[i]).length);
          }
          _spurious['${m.label} | ${cfg.label}'] = (_spurious['${m.label} | ${cfg.label}'] ?? 0) + invented;
          final before = _HoldBackEmitter();
          _report('${m.label} | ${cfg.label} | hold newest word (before)', clip, _replay(tr, script, clip.words.length, update: before.update, flush: before.flush));
          final live = LiveWordEmitter();
          _report('${m.label} | ${cfg.label} | LiveWordEmitter (now)', clip, _replay(tr, script, clip.words.length, update: (h, _) => live.update(h), flush: () {
            live.reset();
            return const [];
          }));
        }
      }
    }
    for (final e in rtf.entries) {
      // ignore: avoid_print
      print('compute: ${e.key} real-time factor ${(e.value.reduce((a, b) => a + b) / e.value.length).toStringAsFixed(3)} (decode seconds per second of audio, 2 threads, this Mac)');
    }
    _printPool();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
