import 'dart:io' show Platform;

/// Section markers: a line holding only a name in square brackets, like `[Intro]`. A section runs
/// until the next marker. Markers are shown on the prompter as dividers but are never read, counted
/// or highlighted, so every word index stays the same as in the script without them.
///
/// Desktop only for now: on phones and tablets a bracketed line is ordinary text.
final bool sectionMarkersOn = !(Platform.isIOS || Platform.isAndroid);

/// Longest section name.
const maxSectionNameLength = 40;

final _markerLine = RegExp(r'^[ \t]*\[([^\[\]\r\n]{1,40})\][ \t\r]*$', multiLine: true);
final _word = RegExp(r'\S+');

/// True if [line] (one line, no line break) is a section marker.
bool isSectionMarkerLine(String line) {
  if (!sectionMarkersOn) return false;
  final m = _markerLine.firstMatch(line);
  return m != null && m[1]!.trim().isNotEmpty;
}

class SectionMarker {
  const SectionMarker({required this.name, required this.start, required this.end, required this.wordIndex});

  /// Name without the brackets.
  final String name;

  /// Characters of the marker line in the script, brackets included.
  final int start;
  final int end;

  /// Index of the first spoken word in this section.
  final int wordIndex;
}

/// Every marker in [script], in order. Empty when markers are off or there are none.
List<SectionMarker> sectionMarkers(String script) {
  if (!sectionMarkersOn || !script.contains('[')) return const [];
  final raw = [
    for (final m in _markerLine.allMatches(script))
      if (m[1]!.trim().isNotEmpty) m,
  ];
  if (raw.isEmpty) return const [];
  final out = <SectionMarker>[];
  var words = 0;
  final matches = _word.allMatches(script).iterator;
  var hasWord = matches.moveNext();
  for (final m in raw) {
    // Count spoken words that start before this marker; words inside earlier markers don't count.
    while (hasWord && matches.current.start < m.start) {
      if (!_insideMarker(matches.current.start, raw)) words++;
      hasWord = matches.moveNext();
    }
    out.add(SectionMarker(name: m[1]!.trim(), start: m.start, end: m.end, wordIndex: words));
  }
  return out;
}

bool _insideMarker(int offset, List<RegExpMatch> markers) {
  for (final m in markers) {
    if (offset >= m.start && offset < m.end) return true;
    if (m.start > offset) return false;
  }
  return false;
}

/// The spoken words of [script] with their character positions: `\S+` runs outside marker lines.
Iterable<RegExpMatch> spokenWordMatches(String script) {
  if (!sectionMarkersOn || !script.contains('[')) return _word.allMatches(script);
  final raw = [
    for (final m in _markerLine.allMatches(script))
      if (m[1]!.trim().isNotEmpty) m,
  ];
  if (raw.isEmpty) return _word.allMatches(script);
  return _word.allMatches(script).where((w) => !_insideMarker(w.start, raw));
}

/// Index of the section a word belongs to, or -1 before the first marker.
int sectionIndexForWord(List<SectionMarker> markers, int word) {
  var found = -1;
  for (var i = 0; i < markers.length; i++) {
    if (markers[i].wordIndex <= word) {
      found = i;
    } else {
      break;
    }
  }
  return found;
}
