import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/script/saved_script.dart';

/// Script history: JSON metadata in preferences (same key as the POC), bodies
/// as readable `.txt` files in [directory]. Max 20 entries.
class ScriptLibrary {
  ScriptLibrary(this.directory, this._prefs, {this.key = historyKey});

  static const historyKey = 'EchoPrompter.scriptHistory.v1';
  static const maxEntries = 20;

  final Directory directory;
  final SharedPreferences _prefs;

  /// Where the history is kept in preferences; notes use their own so the two lists never mix.
  final String key;

  List<SavedScript> load() {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
    return [
      for (final m in list)
        ?_read(m),
    ];
  }

  SavedScript? _read(Map<String, Object?> m) {
    final name = m['fileName'] as String?;
    if (name == null) return null;
    final f = File(p.join(directory.path, name));
    if (!f.existsSync()) return null;
    return SavedScript(
      id: m['id'] as String,
      body: f.readAsStringSync(),
      savedAt: DateTime.parse(m['savedAt'] as String),
      fileName: name,
      customTitle: m['title'] as String?,
    );
  }

  Future<List<SavedScript>> save(List<SavedScript> history, SavedScript script) async {
    await directory.create(recursive: true);
    var name = script.fileName ?? _fileName(script, history);
    // A changed title renames the file too, so the folder keeps reading like the list.
    final old = history.where((s) => s.id == script.id).firstOrNull;
    if (old != null && script.fileName != null && script.hasCustomTitle && old.customTitle?.trim() != script.customTitle?.trim()) {
      final next = _fileName(script, history);
      if (next != name) {
        try {
          await File(p.join(directory.path, name)).rename(p.join(directory.path, next));
          name = next;
        } on FileSystemException {
          // Keep the old file name; the script still saves.
        }
      }
    }
    await File(p.join(directory.path, name)).writeAsString(script.body);
    final saved = SavedScript(id: script.id, body: script.body, savedAt: DateTime.now(), fileName: name, customTitle: script.customTitle);
    final next = [saved, ...history.where((s) => s.id != script.id)];
    final kept = next.take(maxEntries).toList();
    await persist(kept);
    return kept;
  }

  Future<List<SavedScript>> delete(List<SavedScript> history, SavedScript script) async {
    final f = File(p.join(directory.path, script.fileName ?? ''));
    if (script.fileName != null && f.existsSync()) await f.delete();
    final next = history.where((s) => s.id != script.id).toList();
    await persist(next);
    return next;
  }

  Future<void> persist(List<SavedScript> h) =>
      _prefs.setString(key, jsonEncode([for (final s in h) s.toJson()]));

  /// File name from the script's first line; numbered when taken.
  String _fileName(SavedScript s, List<SavedScript> history) {
    final base = s.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .take(8)
        .join(' ');
    final stem = base.isEmpty ? 'Untitled script' : base;
    final used = {for (final h in history) if (h.id != s.id) h.fileName};
    // Scripts past the history limit leave the list but keep their files, so a
    // name must also be free on disk. Runs once per new script, not per save.
    bool taken(String n) => used.contains(n) || File(p.join(directory.path, n)).existsSync();
    var name = '$stem.txt';
    for (var i = 2; taken(name); i++) {
      name = '$stem $i.txt';
    }
    return name;
  }
}
