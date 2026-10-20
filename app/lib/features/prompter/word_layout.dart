import 'package:flutter/painting.dart';

/// Character ranges of each whitespace-separated word, and their vertical
/// positions once laid out. Highlighting only changes colour/decoration, so
/// one cached layout serves every progress update.
class WordLayout {
  WordLayout(this.script, TextStyle base, double width, {TextAlign align = TextAlign.left}) {
    for (final m in RegExp(r'\S+').allMatches(script)) {
      ranges.add(TextRange(start: m.start, end: m.end));
    }
    painter = TextPainter(
      text: TextSpan(text: script, style: base),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width);
  }

  final String script;
  final List<TextRange> ranges = [];
  late final TextPainter painter;

  double get height => painter.height;

  static final _paragraphGap = RegExp(r'\n\s*\n');

  /// First word of the next paragraph if a blank line follows one of the
  /// [within] words starting at [from], else null.
  int? paragraphStartWithin(int from, int within) {
    final end = (from + within).clamp(0, ranges.length - 1);
    for (var k = from; k < end; k++) {
      if (_paragraphGap.hasMatch(script.substring(ranges[k].end, ranges[k + 1].start))) return k + 1;
    }
    return null;
  }

  /// Vertical centre of word [i].
  double midY(int i) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: ranges[i].start, extentOffset: ranges[i].end),
    );
    if (boxes.isEmpty) return 0;
    return (boxes.first.top + boxes.first.bottom) / 2;
  }

  /// Index of the word at or just after a local text position; clamps to the
  /// last word. Returns 0 for an empty script.
  int nearestWord(Offset p) {
    if (ranges.isEmpty) return 0;
    final off = painter.getPositionForOffset(p).offset;
    var lo = 0, hi = ranges.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ranges[mid].end < off) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Word index at a local text position, or null between words.
  int? wordAt(Offset p) {
    final off = painter.getPositionForOffset(p).offset;
    var lo = 0, hi = ranges.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final r = ranges[mid];
      if (off < r.start) {
        hi = mid - 1;
      } else if (off > r.end) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return null;
  }
}
