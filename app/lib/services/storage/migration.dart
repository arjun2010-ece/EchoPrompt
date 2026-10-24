import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/script/saved_script.dart';
import '../../core/settings/prompt_settings.dart';
import 'script_library.dart';

const _migratedKey = 'EchoPrompter.migratedFromPoc.v1';

/// One-time import for users upgrading from the Swift proof of concept. The
/// bundle ID is unchanged, so scripts are still in the scripts folder; the
/// POC's JSON history lives in a raw UserDefaults key the Flutter plugin
/// can't see, so the history is rebuilt from the `.txt` files (newest first).
Future<PromptSettings?> migrateFromPoc({
  required SharedPreferences prefs,
  required ScriptLibrary library,
  required PromptSettings current,
  required Map<String, Object?> legacyDefaults,
}) async {
  if (prefs.getBool(_migratedKey) ?? false) return null;
  await prefs.setBool(_migratedKey, true);

  if (library.load().isEmpty && library.directory.existsSync()) {
    final files = library.directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final history = <SavedScript>[
      for (final (i, f) in files.take(ScriptLibrary.maxEntries).indexed)
        SavedScript(
          id: 'poc-$i-${f.lastModifiedSync().microsecondsSinceEpoch}',
          body: f.readAsStringSync(),
          savedAt: f.lastModifiedSync(),
          fileName: p.basename(f.path),
        ),
    ];
    if (history.isNotEmpty) await library.persist(history);
  }

  if (legacyDefaults.isEmpty) return null;
  T? e<T extends Enum>(List<T> v, Object? n) => v.where((x) => x.name == n).firstOrNull;
  return current.copyWith(
    placement: e(PromptPlacement.values, legacyDefaults['placement']),
    corner: e(PromptCorner.values, legacyDefaults['corner']),
    hideFromCapture: legacyDefaults['hideFromCapture'] as bool?,
  );
}
