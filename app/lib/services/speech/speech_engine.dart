import 'dart:typed_data';

import '../../core/matching/audio_aligner.dart';

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

Float32List pcm16ToFloat(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
