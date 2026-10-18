import 'dart:math' as math;

import '../script/text.dart';

class TranscriptToken {
  const TranscriptToken(this.word, this.time);
  final String word;
  final double time;
}

class TimedWord {
  const TimedWord(this.scriptIndex, this.time);
  final int scriptIndex;
  final double time;
}

/// A recognised segment with a timestamp, as produced by an offline ASR.
class TranscriptSegment {
  const TranscriptSegment(this.text, this.timestamp, this.duration);
  final String text;
  final double timestamp;
  final double duration;
}

/// Spreads each segment's words evenly across its duration.
List<TranscriptToken> tokensFromSegments(List<TranscriptSegment> segments) {
  final ordered = [...segments]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return [
    for (final s in ordered)
      ...() {
        final words = spokenWords(s.text);
        if (words.isEmpty) return <TranscriptToken>[];
        final interval = s.duration / words.length;
        return [
          for (var i = 0; i < words.length; i++)
            TranscriptToken(words[i], s.timestamp + i * interval),
        ];
      }(),
  ];
}

/// Port of `RecordedAudioController.align`: maps timestamped tokens to script
/// word indices, accepting only the next expected word or a uniquely
/// phrase-confirmed nearby word.
List<TimedWord> alignTranscript({
  required List<TranscriptToken> tokens,
  required List<TranscriptSegment> segments,
  required String script,
  required double audioDuration,
}) {
  final words = scriptWords(script);
  var scriptIndex = -1;
  final result = <TimedWord>[];

  for (var t = 0; t < tokens.length; t++) {
    final token = tokens[t];
    final start = math.max(0, scriptIndex + 1);
    if (start >= words.length) break;

    if (wordsMatch(words[start], token.word)) {
      scriptIndex = start;
      result.add(TimedWord(start, token.time));
      continue;
    }
    if (token.word.length < 4) continue;
    final end = math.min(words.length, start + 5);
    final candidates = <int>[
      for (var c = start; c < end; c++)
        if (wordsMatch(words[c], token.word) && _confirmed(tokens, t, words, c)) c,
    ];
    if (candidates.length == 1) {
      scriptIndex = candidates.first;
      result.add(TimedWord(scriptIndex, token.time));
    }
  }

  // Calibrate the timebase only on a meaningful discrepancy.
  final recognizedEnd =
      segments.map((s) => s.timestamp + s.duration).fold<double>(0, math.max);
  if (audioDuration <= 0 || recognizedEnd <= 0) return result;
  final scale = audioDuration / recognizedEnd;
  if ((scale - 1).abs() <= 0.025) return result;
  return [
    for (final w in result)
      TimedWord(w.scriptIndex, math.min(audioDuration, math.max(0, w.time * scale))),
  ];
}

bool _confirmed(
  List<TranscriptToken> tokens,
  int tokenIndex,
  List<String> words,
  int scriptIndex,
) {
  final s = scriptIndex + 1;
  final e = math.min(words.length, s + 4);
  if (s >= e) return false;
  for (final t in tokens.skip(tokenIndex + 1).take(4)) {
    if (t.word.length >= 3 &&
        Iterable<int>.generate(e - s, (k) => s + k).any((k) => wordsMatch(words[k], t.word))) {
      return true;
    }
  }
  return false;
}

/// Guardrail so a malformed timeline can't race far ahead of the audio.
int pacingCeiling({
  required double elapsed,
  required double audioDuration,
  required int scriptWordCount,
}) {
  if (audioDuration <= 0 || scriptWordCount <= 0) return 1 << 62;
  final avg = scriptWordCount / audioDuration;
  final maxWps = math.max(5.0, avg * 2.0);
  return math.min(scriptWordCount - 1, (elapsed * maxWps + 6.0).floor());
}

/// Latest word whose time has passed and is under the pacing ceiling.
int? currentWordAt({
  required List<TimedWord> timed,
  required double elapsed,
  required int ceiling,
}) {
  for (var i = timed.length - 1; i >= 0; i--) {
    if (timed[i].time <= elapsed && timed[i].scriptIndex <= ceiling) {
      return timed[i].scriptIndex;
    }
  }
  return null;
}
