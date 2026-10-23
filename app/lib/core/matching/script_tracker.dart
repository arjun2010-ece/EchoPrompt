import '../script/text.dart';

final _apostrophes = RegExp("['’]");
final _edgePunctuation = RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true);

/// Voice-script tracker for recognisers that report their whole running
/// hypothesis (Android `SpeechRecognizer`). It is re-run on every changed partial
/// result and matches the last few spoken words against an n-gram window of the
/// script ahead of the cursor, so the highlight follows the speaker without waiting
/// for a recogniser to finish a sentence. See `docs/android-voice-tracking-implementation.md`.
///
/// Eligible script words are those with letters or digits; the rest are skipped.
class ScriptTracker {
  ScriptTracker(List<String> words, {int lookahead = 150, this.allowBackward = false})
    : _raw = words,
      _clean = [for (final w in words) normalizeWord(w)],
      _lookahead = lookahead.clamp(5, 150);

  final List<String> _raw;
  final List<String> _clean;
  final int _lookahead;

  /// Lets a strong match (4+ words) behind the cursor move it back.
  final bool allowBackward;

  static const _tailLength = 6;

  /// Index of the next word expected.
  int _d = 0;

  /// First script word of the last accepted match, and when it was accepted.
  String _anchor = '';
  int _anchoredAt = 0;
  int _lastMatched = -1;

  int get cursor => _d;

  /// Index of the last script word matched, -1 before anything is read.
  int get lastMatched => _lastMatched;

  /// Points the tracker at a position set from outside (a tap, a restart): [confirmed] is
  /// the last word read. A no-op when it is already there.
  void syncTo(int confirmed) {
    if (confirmed == _lastMatched) return;
    _lastMatched = confirmed;
    _d = (confirmed + 1).clamp(0, _clean.length);
    endUtterance();
  }

  /// The recogniser finished a result; the next hypothesis starts from nothing.
  void endUtterance() {
    _anchor = '';
    _anchoredAt = 0;
  }

  /// The next [lookahead] script words, lowercased and de-duplicated, for the recogniser's
  /// vocabulary bias.
  List<String> biasingWords() {
    final out = <String>{};
    var count = 0;
    for (var i = _d; i < _clean.length && count < _lookahead; i++) {
      if (_clean[i].isEmpty) continue;
      count++;
      final w = _raw[i].toLowerCase().replaceAll(_edgePunctuation, '');
      if (w.isNotEmpty) out.add(w);
    }
    return out.toList();
  }

  /// Consumes the recogniser's current [text]; returns the new cursor, or null if it did
  /// not move. [nowMs] is any monotonic clock in milliseconds.
  int? update(String text, int nowMs) {
    final n = _clean.length;
    if (_d > n) _d = n;
    final spoken = spokenWords(text.replaceAll(_apostrophes, ''));
    if (spoken.isEmpty) return null;

    final history = _history();
    final consumed = _consumedCount(spoken, history);
    final fresh = spoken.sublist(consumed);
    final tail = fresh.length > _tailLength ? fresh.sublist(fresh.length - _tailLength) : fresh;
    if (tail.isEmpty) return null;

    final start = allowBackward ? (_d - _lookahead).clamp(0, n) : _d;
    var bestIndex = -1;
    var bestScore = 0;
    var forward = 0;
    for (var i = start; i < n; i++) {
      if (_clean[i].isEmpty) continue;
      final offset = i < _d ? i - _d : forward;
      final word = _clean[i];
      if (tail.contains(word)) {
        final score = _score(i, tail);
        final repeated = word == _anchor && offset > 0 && nowMs - _anchoredAt < 1500;
        if (_accepts(offset, score, word.length) && !repeated) {
          if (bestIndex < 0 ||
              score >= bestScore + 2 ||
              ((score - bestScore).abs() < 2 && (i - _d).abs() < (bestIndex - _d).abs())) {
            bestIndex = i;
            bestScore = score;
          }
        }
      }
      if (offset >= 0 && ++forward > _lookahead) break;
    }
    if (bestIndex < 0) return null;

    _anchor = _clean[bestIndex];
    _anchoredAt = nowMs;
    var i = bestIndex;
    var left = bestScore;
    while (i < n && left > 0) {
      if (_clean[i].isNotEmpty) {
        left--;
        _lastMatched = i;
      }
      i++;
    }
    while (i < n && _clean[i].isEmpty) {
      i++;
    }
    return _d = i;
  }

  /// Up to three eligible words before the cursor, oldest first.
  List<String> _history() {
    final h = <String>[];
    for (var i = _d - 1; i >= 0 && h.length < 3; i--) {
      if (_clean[i].isNotEmpty) h.add(_clean[i]);
    }
    return h.reversed.toList();
  }

  /// How many leading spoken words were already read: a hypothesis holds the whole
  /// utterance so far, so words up to the latest sighting of what was just read are old.
  /// A lone repeated word ("the") only counts when its neighbours corroborate it.
  int _consumedCount(List<String> spoken, List<String> history) {
    if (history.isEmpty) return 0;
    for (final w in history.reversed.take(2)) {
      for (var pos = spoken.length - 1; pos >= 0; pos--) {
        if (spoken[pos] != w) continue;
        var evidence = 0;
        if (history.length == 1) {
          evidence = 1;
        } else {
          for (var k = pos - 6 < 0 ? 0 : pos - 6; k < pos; k++) {
            if (spoken[k] != w && history.contains(spoken[k])) evidence++;
          }
        }
        if (evidence > 0) return pos + 1;
      }
    }
    return 0;
  }

  /// The longest run of script words from [index] found in [tail], tolerating one extra
  /// spoken word between consecutive script words.
  int _score(int index, List<String> tail) {
    final g = <String>[];
    for (var i = index; i < _clean.length && g.length < tail.length; i++) {
      if (_clean[i].isNotEmpty) g.add(_clean[i]);
    }
    var best = 0;
    for (var s = 0; s < tail.length; s++) {
      if (tail[s] != g[0]) continue;
      var p = s + 1;
      var k = 1;
      for (var j = 1; j < g.length; j++) {
        if (p < tail.length && tail[p] == g[j]) {
          p += 1;
        } else if (p + 1 < tail.length && tail[p + 1] == g[j]) {
          p += 2;
        } else {
          break;
        }
        k++;
      }
      if (k > best) best = k;
    }
    return best;
  }

  /// The further a candidate is from the cursor, the more consecutive words must agree.
  bool _accepts(int offset, int score, int length) {
    if (score < 1) return false;
    if (offset < 0) return (offset >= -20 && score >= 4) || score >= 5;
    if (offset <= 1) return true;
    if (offset <= 4) return score >= 2 || length >= 4;
    if (offset <= 8) return score >= 2;
    if (offset <= 12) return score >= 3;
    if (offset <= 20) return score >= 4;
    return score >= 5;
  }
}
