import '../script/text.dart';

/// Conservative live-voice follower (port of `PromptView.follow(spoken:)`).
///
/// Short/common words advance only when they are the next expected word.
/// Favour falling behind over skipping ahead.
class VoiceMatcher {
  VoiceMatcher(String script) : words = scriptWords(script);

  final List<String> words;

  /// Returns the new active word index after consuming [spoken], starting
  /// from [activeIndex] (-1 before anything is read).
  int follow(List<String> spoken, int activeIndex) {
    if (words.isEmpty) return activeIndex;
    var next = activeIndex;

    for (var i = 0; i < spoken.length; i++) {
      final target = normalizeWord(spoken[i]);
      if (target.isEmpty) continue;
      final start = next + 1 < 0 ? 0 : next + 1;
      if (start >= words.length) break;

      if (wordsMatch(words[start], target)) {
        next = start;
        continue;
      }
      if (target.length < 4) continue;

      // Recover a nearby skipped/misheard word.
      final nearbyEnd = (start + 8).clamp(0, words.length);
      var found = -1;
      for (var j = start; j < nearbyEnd; j++) {
        if (wordsMatch(words[j], target)) {
          found = j;
          break;
        }
      }
      if (found >= 0) {
        next = found;
        continue;
      }

      // Longer recovery only with phrase confirmation and a unique candidate.
      if (target.length < 5) continue;
      final recoveryEnd = (start + 20).clamp(0, words.length);
      final candidates = <int>[
        for (var c = start; c < recoveryEnd; c++)
          if (wordsMatch(words[c], target) && _confirmed(spoken, i, c)) c,
      ];
      if (candidates.length == 1) next = candidates.first;
    }
    return next;
  }

  bool _confirmed(List<String> spoken, int spokenIndex, int scriptIndex) {
    final s = scriptIndex + 1;
    final e = (s + 4).clamp(0, words.length);
    if (s >= e) return false;
    for (final w in spoken.skip(spokenIndex + 1)) {
      final t = normalizeWord(w);
      if (t.length < 3) continue;
      for (var k = s; k < e; k++) {
        if (wordsMatch(words[k], t)) return true;
      }
    }
    return false;
  }
}
