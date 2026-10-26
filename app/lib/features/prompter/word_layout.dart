import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../core/script/sections.dart';

/// Character ranges of each whitespace-separated word, and their vertical
/// positions once laid out. Highlighting only changes colour/decoration, so
/// one cached layout serves every progress update.
///
/// Section markers (`[Intro]`) are drawn as a divider line and are not words: [ranges] skips them, so
/// word indices match the script without markers. [script] is the text as shown (dividers in place
/// of the markers), and every offset here refers to it.
class WordLayout {
  WordLayout(String raw, TextStyle base, double width, {TextAlign align = TextAlign.left, bool showSections = true}) {
    markers = sectionMarkers(raw);
    dividerStyle = base.copyWith(
      fontSize: math.max(11.0, (base.fontSize ?? 24) * 0.38),
      fontWeight: FontWeight.w700,
      letterSpacing: 2.2,
      color: const Color(0xFF9A9AA0),
    );
    final shown = StringBuffer();
    var cursor = 0;
    for (final m in markers) {
      shown.write(raw.substring(cursor, m.start));
      if (showSections) {
        final start = shown.length;
        shown.write('────  ${m.name.toUpperCase()}  ────');
        dividerRanges.add(TextRange(start: start, end: shown.length));
      }
      cursor = m.end;
    }
    shown.write(raw.substring(cursor));
    script = shown.toString();
    for (final m in RegExp(r'\S+').allMatches(script)) {
      if (!_inDivider(m.start)) ranges.add(TextRange(start: m.start, end: m.end));
    }
    painter = TextPainter(
      text: TextSpan(style: base, children: gapSpans(0, script.length)),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width);
  }

  /// The text as shown.
  late final String script;
  final List<TextRange> ranges = [];

  /// Section markers of the script, whether or not dividers are shown.
  late final List<SectionMarker> markers;
  final List<TextRange> dividerRanges = [];
  late final TextStyle dividerStyle;
  late final TextPainter painter;

  bool _inDivider(int offset) {
    for (final d in dividerRanges) {
      if (offset >= d.start && offset < d.end) return true;
    }
    return false;
  }

  /// The text between words from [from] to [to], with any divider in it drawn in its own style.
  List<InlineSpan> gapSpans(int from, int to) {
    final out = <InlineSpan>[];
    var at = from;
    for (final d in dividerRanges) {
      if (d.end <= at || d.start >= to) continue;
      if (d.start > at) out.add(TextSpan(text: script.substring(at, d.start)));
      out.add(TextSpan(text: script.substring(d.start, d.end), style: dividerStyle));
      at = d.end;
    }
    if (at < to) out.add(TextSpan(text: script.substring(at, to)));
    return out;
  }

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
