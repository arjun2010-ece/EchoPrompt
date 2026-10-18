import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/script/saved_script.dart';

/// Script history: JSON metadata in preferences (same key as the POC), bodies
/// as readable `.txt` files in [directory]. Max 20 entries.
class ScriptLibrary {
  ScriptLibrary(this.directory, this._prefs);

  static const historyKey = 'EchoPrompt.scriptHistory.v1';
  static const maxEntries = 20;

  final Directory directory;
  final SharedPreferences _prefs;

  List<SavedScript> load() {
    final raw = _prefs.getString(historyKey);
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
    );
  }

  Future<List<SavedScript>> save(List<SavedScript> history, SavedScript script) async {
    await directory.create(recursive: true);
    final name = script.fileName ?? _fileName(script, history);
    await File(p.join(directory.path, name)).writeAsString(script.body);
    final saved = SavedScript(id: script.id, body: script.body, savedAt: DateTime.now(), fileName: name);
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
      _prefs.setString(historyKey, jsonEncode([for (final s in h) s.toJson()]));

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
    var name = '$stem.txt';
    for (var i = 2; used.contains(name); i++) {
      name = '$stem $i.txt';
    }
    return name;
  }
}
