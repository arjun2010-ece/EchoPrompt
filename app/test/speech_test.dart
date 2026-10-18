import 'dart:typed_data';

import 'package:echoprompt/services/speech/speech_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('groups sentencepiece tokens into timed words', () {
    final w = groupTokensIntoWords(['▁HEL', 'LO', '▁WORLD'], [0.0, 0.1, 0.5], endTime: 1.0);
    expect(w.map((e) => e.text), ['HEL' 'LO', 'WORLD']);
    expect(w.first.timestamp, 0.0);
    expect(w.first.duration, closeTo(0.5, 1e-9));
    expect(w.last.duration, closeTo(0.5, 1e-9));
  });

  test('newWordsSince reports only the unseen tail', () {
    expect(newWordsSince(['a', 'b', 'c'], 2), ['c']);
    expect(newWordsSince(['a'], 3), isEmpty);
  });

  test('pcm16 converts to normalised floats', () {
    final bytes = Uint8List.fromList([0x00, 0x40, 0x00, 0xC0]); // 16384, -16384
    final f = pcm16ToFloat(bytes);
    expect(f[0], closeTo(0.5, 1e-6));
    expect(f[1], closeTo(-0.5, 1e-6));
  });
}
