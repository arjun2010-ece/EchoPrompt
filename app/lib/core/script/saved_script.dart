import 'dart:convert';

/// Script history entry. Metadata is JSON in preferences; the body lives in a
/// `.txt` file. [fingerprint] is a stable content hash kept for the paywall.
class SavedScript {
  SavedScript({
    required this.id,
    required this.body,
    required this.savedAt,
    this.fileName,
  });

  final String id;
  final String body;
  final DateTime savedAt;
  final String? fileName;

  String get title {
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isNotEmpty) return line;
    }
    return 'Untitled script';
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
  };

  SavedScript withBody(String body) =>
      SavedScript(id: id, body: body, savedAt: savedAt, fileName: fileName);
}
