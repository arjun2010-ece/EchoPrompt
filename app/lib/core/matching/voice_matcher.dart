import '../script/text.dart';

/// Conservative live-voice follower (port of `PromptView.follow(spoken:)`).
///
/// Short/common words advance only when they are the next expected word.
/// Favour falling behind over skipping ahead. Beyond the POC it also:
/// * accepts a word spoken as several tokens ("I'm" -> "i m", "everyone" ->
///   "every one") or written as digits/symbols ("40%" -> "forty percent"),
/// * tolerates a one-letter recognition error in longer words, and
/// * re-anchors anywhere ahead in the script once a few spoken words in a row
///   line up with it, so a missed or misheard phrase can never strand the
///   highlight.
class VoiceMatcher {
  VoiceMatcher(String script)
    : words = scriptWords(script),
      _norm = [for (final w in scriptWords(script)) normalizeWord(w)];

  final List<String> words;
  final List<String> _norm;
  final _forms = <int, List<List<String>>>{};

  /// Spoken words since the last advance (unmatched, in order).
  final _window = <String>[];
  static const _windowCap = 14;

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

      if (_matches(_norm[start], target)) {
        next = start;
        _window.clear();
        continue;
      }
      _window.add(target);
      if (_window.length > _windowCap) _window.removeAt(0);

      if (_compound(start)) {
        next = start;
        _window.clear();
        continue;
      }
      if (target.length < 4) continue;

      // Recover a nearby skipped/misheard word.
      final nearbyEnd = (start + 8).clamp(0, words.length);
      var found = -1;
      for (var j = start; j < nearbyEnd; j++) {
        if (_matches(_norm[j], target)) {
          found = j;
          break;
        }
      }
      if (found >= 0) {
        next = found;
        _window.clear();
        continue;
      }

      // Longer recovery only with phrase confirmation and a unique candidate.
      if (target.length < 5) continue;
      final recoveryEnd = (start + 20).clamp(0, words.length);
      final candidates = <int>[
        for (var c = start; c < recoveryEnd; c++)
          if (_matches(_norm[c], target) && _confirmed(spoken, i, c)) c,
      ];
      if (candidates.length == 1) {
        next = candidates.first;
        _window.clear();
      }
    }

    final anchored = _reanchor(next) ?? _reread(next);
    if (anchored != null) {
      next = anchored;
      _window.clear();
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
        if (_matches(_norm[k], t)) return true;
      }
    }
    return false;
  }

  // --- matching helpers ----------------------------------------------------

  /// [wordsMatch] plus one-letter slack for words of five or more letters.
  bool _matches(String expected, String spoken) =>
      expected == spoken ||
      (spoken.length >= 4 && expected.contains(spoken)) ||
      (expected.length >= 5 && spoken.length >= 5 && _withinOneEdit(expected, spoken));

  /// The expected word spoken as 2–3 tokens ("im" <- "i m") or as numbers.
  bool _compound(int index) {
    final expected = _norm[index];
    if (expected.isEmpty) return false;
    for (var m = 2; m <= 3 && m <= _window.length; m++) {
      final joined = _window.sublist(_window.length - m).join();
      if (joined == expected || (expected.length >= 5 && _withinOneEdit(expected, joined))) return true;
    }
    final spokenForms = _formsFor(index);
    if (spokenForms.isEmpty) return false;
    final tail = [for (final t in _window) if (t != 'and') _homophone(t)];
    for (final form in spokenForms) {
      if (tail.length < form.length) continue;
      var ok = true;
      for (var k = 0; k < form.length && ok; k++) {
        ok = tail[tail.length - form.length + k] == form[k];
      }
      if (ok) return true;
    }
    return false;
  }

  List<List<String>> _formsFor(int index) => _forms.putIfAbsent(index, () => _spokenForms(words[index]));

  // --- re-anchoring --------------------------------------------------------

  /// When spoken words since the last advance line up with a run of script
  /// words further ahead (allowing one slip), jump there. Forward only.
  int? _reanchor(int active) {
    final toks = _window;
    if (toks.length < 3) return null;
    int? bestEnd;
    var bestScore = 0;
    var bestDist = 1 << 30;
    for (var a = 0; a <= toks.length - 3; a++) {
      for (var p = 0; p < words.length; p++) {
        if (_norm[p].isEmpty || !(_tokMatch(toks, a, 1, p) || _tokMatch(toks, a, 2, p) || _formLength(toks, a, p) > 0)) continue;
        final r = _walk(toks, a, p, 1, -1);
        if (r == null || r.end <= active) continue;
        final dist = (p - (active + 1)).abs();
        final near = dist <= 30;
        final ok = near ? (r.count >= 3 && r.content >= 2 && r.score >= 12 || r.count >= 4 && r.content >= 1 && r.score >= 13) : (r.count >= 4 && r.content >= 3 && r.score >= 20);
        if (!ok) continue;
        if (r.score > bestScore || (r.score == bestScore && dist < bestDist)) {
          bestScore = r.score;
          bestDist = dist;
          bestEnd = r.end;
        }
      }
    }
    return bestEnd;
  }

  /// The reader went back and repeated an earlier passage: the spoken words since the last
  /// advance line up with a run of script words *behind* [active]. Only tried when nothing
  /// ahead matched, and only for a long run with several real words, because short phrases
  /// repeat all the time. Returns the last word of the repeated run.
  int? _reread(int active) {
    final toks = _window;
    if (toks.length < 4 || active < 1) return null;
    int? bestEnd;
    var bestScore = 0;
    for (var a = 0; a <= toks.length - 4; a++) {
      for (var p = 0; p < active; p++) {
        if (_norm[p].isEmpty || !(_tokMatch(toks, a, 1, p) || _tokMatch(toks, a, 2, p) || _formLength(toks, a, p) > 0)) continue;
        final r = _walk(toks, a, p, 1, -1);
        if (r == null || r.end >= active || r.count < 4 || r.content < 3 || r.score < 20) continue;
        if (r.score > bestScore || (r.score == bestScore && r.end > bestEnd!)) {
          bestScore = r.score;
          bestEnd = r.end;
        }
      }
    }
    return bestEnd;
  }

  bool _tokMatch(List<String> toks, int t, int m, int w) {
    final expected = _norm[w];
    if (t + m > toks.length || expected.isEmpty) return false;
    if (m == 1) return _matches(expected, toks[t]);
    final joined = toks.sublist(t, t + m).join();
    return joined == expected || (expected.length >= 5 && _withinOneEdit(expected, joined));
  }

  /// Tokens used if script word [w] is spoken as numbers starting at [t]
  /// ("and" may be dropped in between); 0 if it isn't.
  int _formLength(List<String> toks, int t, int w) {
    for (final form in _formsFor(w)) {
      var i = t;
      var ok = true;
      for (var k = 0; k < form.length && ok; k++) {
        if (i < toks.length && toks[i] == 'and' && form[k] != 'and') i++;
        ok = i < toks.length && _homophone(toks[i]) == form[k];
        i++;
      }
      if (ok) return i - t;
    }
    return 0;
  }

  /// Aligns tokens from [t] with script words from [w], consuming all of them.
  /// One spoken or script word may be skipped ([skips]). Null if it fails.
  _Alignment? _walk(List<String> toks, int t, int w, int skips, int lastMatched) {
    if (t >= toks.length) return _Alignment(lastMatched);
    if (w >= words.length) return null;
    _Alignment? best;
    void consider(_Alignment? r) {
      if (r != null && (best == null || r.score > best!.score)) best = r;
    }

    for (var m = 1; m <= 3; m++) {
      if (_tokMatch(toks, t, m, w)) {
        final r = _walk(toks, t + m, w + 1, skips, w);
        if (r != null) consider(r.plus(_norm[w].length));
      }
    }
    final used = _formLength(toks, t, w);
    if (used > 0) {
      final r = _walk(toks, t + used, w + 1, skips, w);
      if (r != null) consider(r.plus(6));
    }
    if (skips > 0 && lastMatched >= 0) {
      consider(_walk(toks, t + 1, w, skips - 1, lastMatched));
      consider(_walk(toks, t, w + 1, skips - 1, lastMatched));
    }
    return best;
  }
}

class _Alignment {
  _Alignment(this.end, [this.score = 0, this.count = 0, this.content = 0]);
  final int end;
  final int score;
  final int count;
  final int content;

  /// Adds one matched script word of [letters] letters.
  _Alignment plus(int letters) => _Alignment(
    end,
    score + (letters > 8 ? 8 : letters),
    count + 1,
    content + (letters >= 4 ? 1 : 0),
  );
}

bool _withinOneEdit(String a, String b) {
  if ((a.length - b.length).abs() > 1) return false;
  var i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
      i++;
      j++;
      continue;
    }
    if (++edits > 1) return false;
    if (a.length > b.length) {
      i++;
    } else if (a.length < b.length) {
      j++;
    } else {
      i++;
      j++;
    }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}

// --- numbers and symbols spoken aloud ----------------------------------------

const _homophones = {'to': 'two', 'too': 'two', 'for': 'four', 'fore': 'four', 'won': 'one', 'ate': 'eight'};
String _homophone(String t) => _homophones[t] ?? t;

const _ones = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven',
  'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const _tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

List<String> _numberWords(int n) {
  if (n < 20) return [_ones[n]];
  if (n < 100) return [_tens[n ~/ 10], if (n % 10 != 0) _ones[n % 10]];
  if (n < 1000) return [_ones[n ~/ 100], 'hundred', if (n % 100 != 0) ..._numberWords(n % 100)];
  if (n < 1000000) return [..._numberWords(n ~/ 1000), 'thousand', if (n % 1000 != 0) ..._numberWords(n % 1000)];
  return [..._numberWords(n ~/ 1000000), 'million', if (n % 1000000 != 0) ..._numberWords(n % 1000000)];
}

String _ordinal(String w) {
  const special = {
    'one': 'first', 'two': 'second', 'three': 'third', 'five': 'fifth', 'eight': 'eighth',
    'nine': 'ninth', 'twelve': 'twelfth',
  };
  if (special.containsKey(w)) return special[w]!;
  if (w.endsWith('y')) return '${w.substring(0, w.length - 1)}ieth';
  return '${w}th';
}

final _numberToken = RegExp(r'^([$£€])?(\d[\d,]*)(?:\.(\d+))?(%|st|nd|rd|th)?$', caseSensitive: false);

/// "we're" may be recognised as "we are", "don't" as "do not", and so on.
List<List<String>> _contractionForms(String word) {
  final w = word.toLowerCase().replaceAll('\u2019', "'");
  const irregular = {
    "can't": ['can', 'not'],
    "won't": ['will', 'not'],
    "shan't": ['shall', 'not'],
    "let's": ['let', 'us'],
    "ain't": ['is', 'not'],
  };
  if (irregular.containsKey(w)) return [irregular[w]!];
  if (w.endsWith("n't")) return [[w.substring(0, w.length - 3), 'not']];
  const suffixes = {
    "'re": ['are'],
    "'ve": ['have'],
    "'ll": ['will'],
    "'m": ['am'],
    "'d": ['would', 'had'],
    "'s": ['is', 'has'],
  };
  for (final e in suffixes.entries) {
    if (w.length > e.key.length + 1 && w.endsWith(e.key)) {
      final stem = w.substring(0, w.length - e.key.length);
      return [for (final x in e.value) [stem, x]];
    }
  }
  return const [];
}

/// How a script word containing digits/symbols may be spoken, as token lists.
List<List<String>> _spokenForms(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'^[^\w$£€]+|[^\w%]+$'), '');
  if (cleaned == '&') return [['and']];
  final m = _numberToken.firstMatch(cleaned);
  if (m == null) return _contractionForms(cleaned);
  final digits = m.group(2)!.replaceAll(',', '');
  if (digits.length > 9) return const [];
  final n = int.parse(digits);
  final bases = <List<String>>[_numberWords(n)];
  final yearLike = m.group(2)!.length == 4 && n >= 1100 && n <= 2099;
  if (yearLike && !(n >= 2000 && n <= 2009)) {
    final hi = n ~/ 100, lo = n % 100;
    bases.add([
      ..._numberWords(hi),
      if (lo == 0) 'hundred' else if (lo < 10) ...['oh', ..._numberWords(lo)] else ..._numberWords(lo),
    ]);
  }
  final frac = m.group(3);
  if (frac != null) {
    final tail = ['point', for (final d in frac.split('')) _ones[int.parse(d)]];
    for (var i = 0; i < bases.length; i++) {
      bases[i] = [...bases[i], ...tail];
    }
  }
  final suffix = m.group(4)?.toLowerCase();
  final currency = m.group(1);
  if (suffix == '%') {
    return [
      for (final b in bases) ...[
        [...b, 'percent'],
        [...b, 'per', 'cent'],
      ],
    ];
  }
  if (suffix != null) {
    final b = bases.first;
    return [[...b.sublist(0, b.length - 1), _ordinal(b.last)]];
  }
  if (currency != null) {
    final unit = switch (currency) {
      r'$' => n == 1 ? 'dollar' : 'dollars',
      '£' => n == 1 ? 'pound' : 'pounds',
      _ => 'euros',
    };
    return [for (final b in bases) [...b, unit]];
  }
  return bases;
}
