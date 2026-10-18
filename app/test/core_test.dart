import 'package:echoprompt/core/matching/audio_aligner.dart';
import 'package:echoprompt/core/matching/voice_matcher.dart';
import 'package:echoprompt/core/progress/reading_progress.dart';
import 'package:echoprompt/core/script/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizeWord is Unicode-aware', () {
    expect(normalizeWord('Hello,'), 'hello');
    expect(normalizeWord('Café!'), 'café');
    expect(normalizeWord('...'), '');
  });

  group('VoiceMatcher', () {
    final m = VoiceMatcher('Welcome to the show. Today we discuss astronomy and telescopes.');

    test('advances word by word', () {
      expect(m.follow(['welcome', 'to', 'the'], -1), 2);
    });
    test('short word out of order does not jump', () {
      expect(m.follow(['we'], -1), -1);
    });
    test('recovers a nearby long word', () {
      expect(m.follow(['welcome', 'discuss'], -1), 6);
    });
    test('ignores filler', () {
      expect(m.follow(['um', 'welcome', 'uh'], -1), 0);
    });
  });

  test('alignTranscript matches in order and skips unconfirmed jumps', () {
    const segs = [TranscriptSegment('welcome to the show', 0, 2)];
    final tokens = tokensFromSegments(segs);
    final timed = alignTranscript(
      tokens: tokens,
      segments: segs,
      script: 'Welcome to the show today',
      audioDuration: 2,
    );
    expect(timed.map((w) => w.scriptIndex), [0, 1, 2, 3]);
    expect(timed.first.time, 0);
  });

  test('pacingCeiling bounds early progress', () {
    expect(pacingCeiling(elapsed: 0, audioDuration: 60, scriptWordCount: 100), 6);
  });

  test('reading progress states', () {
    final p = PromptReadingProgress.synchronized(confirmed: 3, predicted: 4);
    expect(p.stateFor(1), WordState.completed);
    expect(p.stateFor(3), WordState.current);
    expect(p.stateFor(4), WordState.predicted);
    expect(p.stateFor(9), WordState.upcoming);
  });
}
