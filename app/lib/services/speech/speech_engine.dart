import 'dart:typed_data';

import '../../core/matching/audio_aligner.dart';
import '../../core/script/text.dart';

/// Streaming + offline recognition behind one interface so engines can be
/// swapped (plan §5). Implementations must be on-device.
abstract class SpeechEngine {
  /// Loads the model. Throws [SpeechUnavailable] if it isn't installed.
  Future<void> init();

  /// Feeds 16 kHz mono float samples ([-1, 1]) and emits only the words that
  /// are *newly* recognised, so filler absent from the script is ignored by
  /// the matcher without re-processing old words.
  Stream<List<String>> listen(Stream<Float32List> samples);

  /// Offline transcription with token timestamps (Recorded audio mode).
  Future<List<TranscriptSegment>> transcribeFile(String path);

  Future<void> dispose();
}

class SpeechUnavailable implements Exception {
  SpeechUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Groups subword [tokens] (SentencePiece style, '▁' starts a word) into
/// words with the timestamp of their first token.
List<TranscriptSegment> groupTokensIntoWords(
  List<String> tokens,
  List<double> times, {
  double? endTime,
}) {
  final words = <(String, double)>[];
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    final startsWord = t.startsWith('▁') || t.startsWith(' ') || words.isEmpty;
    final piece = t.replaceAll('▁', '').replaceAll(' ', '');
    if (piece.isEmpty) continue;
    final time = i < times.length ? times[i] : 0.0;
    if (startsWord) {
      words.add((piece, time));
    } else {
      words[words.length - 1] = (words.last.$1 + piece, words.last.$2);
    }
  }
  return [
    for (var i = 0; i < words.length; i++)
      TranscriptSegment(
        words[i].$1,
        words[i].$2,
        (i + 1 < words.length ? words[i + 1].$2 : (endTime ?? words[i].$2 + 0.3)) -
            words[i].$2,
      ),
  ];
}

/// Words in [current] not yet reported, given how many were already emitted
/// for this utterance.
List<String> newWordsSince(List<String> current, int alreadyEmitted) =>
    current.length > alreadyEmitted ? current.sublist(alreadyEmitted) : const [];

/// Turns the recogniser's changing hypothesis into words that can be trusted.
/// A streaming recogniser spells a word out piece by piece ("fi" -> "five") and
/// may revise its latest word, so the newest word is held back until the next
/// word starts, the hypothesis stops changing for [settleSeconds] of audio, or
/// the utterance ends ([flush]). The recogniser only refreshes its text every
/// few hundred ms, so the settle time must be well above that.
class StableWordEmitter {
  StableWordEmitter({this.settleSeconds = 0.8});

  final double settleSeconds;
  var _emitted = 0;
  var _last = '';
  var _unchanged = 0.0;

  /// [hypothesis] is the recogniser's current text for the utterance and
  /// [seconds] the audio fed since the previous call.
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

  /// Releases whatever is left at the end of an utterance and starts afresh.
  List<String> flush() {
    final words = spokenWords(_last);
    final fresh = _emitted < words.length ? words.sublist(_emitted) : const <String>[];
    _emitted = 0;
    _last = '';
    _unchanged = 0;
    return fresh;
  }
}

Float32List pcm16ToFloat(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
