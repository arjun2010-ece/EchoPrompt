// ignore_for_file: avoid_print
// Matcher scenarios for backward re-anchoring (no recogniser involved). Run from app/:
//   dart run --packages=.dart_tool/package_config.json tools/voice_latency/matcher_scenarios.dart tools/voice_latency/sample_script.txt
// Each scenario feeds spoken words one at a time and prints where the highlight moves:
// a re-read should jump back after about 5 words; garbled words, a 3-word repeat and a
// 3-word re-read must not.
import 'dart:io';
import 'package:echoprompt/core/matching/voice_matcher.dart';
import 'package:echoprompt/core/script/text.dart';

void main(List<String> args) {
  final script = File(args[0]).readAsStringSync();
  final words = scriptWords(script);
  List<String> say(int from, int to) => [for (var i = from; i <= to; i++) normalizeWord(words[i])];

  void run(String name, List<String> spoken, {int start = -1}) {
    final m = VoiceMatcher(script);
    var cur = start;
    final trail = <String>[];
    for (final w in spoken) {
      final next = m.follow([w], cur);
      if (next != cur) trail.add('${words[next]}#$next');
      cur = next;
    }
    print('$name\n  ended at #$cur (${cur >= 0 ? words[cur] : '-'});  moves: ${trail.join(' ')}');
  }

  // 1. read to "lighting" (#33), re-read "show you three simple ways to make your videos" (#12-#20), then carry on
  run('S1 re-read a sentence, then continue', [...say(0, 33), ...say(12, 20), ...say(21, 28)]);
  // 2. forward reading where the recogniser garbles several words in a row: must never jump back
  run('S2 garbled forward words', [...say(0, 33), 'blah', 'zorp', 'flib', 'quux', 'wibble', ...say(36, 45)]);
  // 3. repeating just the last three words: no jump back
  run('S3 repeat last 3 words', [...say(0, 33), ...say(31, 33), ...say(34, 40)]);
  // 4. re-reading only 3 words of an earlier sentence: not enough evidence
  run('S4 3-word re-read', [...say(0, 33), ...say(14, 16), ...say(34, 40)]);
  // 5. re-read from far back (#2-#9) after reaching #60
  run('S5 re-read a long way back', [...say(0, 60), ...say(2, 9)]);
}
