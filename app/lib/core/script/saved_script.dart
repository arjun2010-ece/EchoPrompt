import 'dart:convert';

import 'sections.dart';

/// Script history entry. Metadata is JSON in preferences; the body lives in a
/// `.txt` file. [fingerprint] is a stable content hash kept for the paywall.
class SavedScript {
  SavedScript({
    required this.id,
    required this.body,
    required this.savedAt,
    this.fileName,
    this.customTitle,
  });

  /// Longest title the editor accepts. It is also the longest that shows whole in every list layout.
  static const maxTitleLength = 24;

  final String id;
  final String body;
  final DateTime savedAt;
  final String? fileName;

  /// Name typed in the Title field. Scripts saved before titles existed, or without one, show
  /// their first line instead.
  final String? customTitle;

  bool get hasCustomTitle => customTitle != null && customTitle!.trim().isNotEmpty;

  String get title {
    if (hasCustomTitle) return customTitle!.trim();
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isNotEmpty && !isSectionMarkerLine(line)) return line;
    }
    return 'Untitled script';
  }

  /// One line for the script list: the start of the text, line breaks folded to spaces. When the
  /// title came from the first line, the preview starts after it so it isn't shown twice.
  String get preview {
    final lines = const LineSplitter().convert(body).where((l) => l.trim().isNotEmpty && !isSectionMarkerLine(l));
    return (hasCustomTitle ? lines : lines.skip(1)).map((l) => l.trim()).join(' ');
  }

  /// FNV-1a over normalised content (whitespace-insensitive).
  String get fingerprint {
    var h = 0xcbf29ce484222325;
    for (final r in body.trim().replaceAll(RegExp(r'\s+'), ' ').runes) {
      h = ((h ^ r) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h.toRadixString(16);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'savedAt': savedAt.toIso8601String(),
    'fileName': fileName,
    if (hasCustomTitle) 'title': customTitle!.trim(),
  };

  SavedScript withBody(String body) =>
      SavedScript(id: id, body: body, savedAt: savedAt, fileName: fileName, customTitle: customTitle);
}
