import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/script/saved_script.dart';
import '../platform.dart';

/// Script import/export. Mobile exports go through the share sheet, which on
/// Android covers the Storage Access Framework and on iOS the Files app.
class ScriptIO {
  static const _importDirKey = 'EchoPrompter.lastImportDir.v1';
  static const _exportDirKey = 'EchoPrompter.lastExportDir.v1';

  /// Folder a picker opens in: the last one used (kept across launches) if it
  /// still exists, else [fallback], created on demand so the dialog can open
  /// there. Exports default to their own folder, never loose in Documents.
  static Future<String?> _startDir(SharedPreferences prefs, String key, Directory fallback) async {
    if (isMobile) return null;
    final last = prefs.getString(key);
    if (last != null && Directory(last).existsSync()) return last;
    await fallback.create(recursive: true);
    return fallback.path;
  }

  /// [scriptsDir] is the library folder; imports open there until the user
  /// picks somewhere else.
  static Future<String?> importText(SharedPreferences prefs, Directory scriptsDir) async =>
      (await importTextFile(prefs, scriptsDir))?.text;

  /// Like [importText], with the file's name so desktop can title the script after it.
  static Future<({String name, String text})?> importTextFile(SharedPreferences prefs, Directory scriptsDir) async {
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md'],
      initialDirectory: await _startDir(prefs, _importDirKey, scriptsDir),
    );
    if (f == null) return null;
    if (f.path != null) await prefs.setString(_importDirKey, p.dirname(f.path!));
    final bytes = await f.readAsBytes();
    return (name: f.name, text: utf8.decode(bytes, allowMalformed: true));
  }

  /// Returns the saved path on desktop, or null if cancelled or shared.
  /// Desktop exports open in `<scriptsDir>/Exports` until the user picks
  /// another folder, which is then remembered.
  static Future<String?> exportText(
    String title,
    String body, {
    required SharedPreferences prefs,
    required Directory scriptsDir,
  }) async {
    final clean = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .take(8)
        .join(' ');
    final name = '${clean.isEmpty ? 'Script' : clean}.txt';
    if (isMobile) {
      await SharePlus.instance.share(ShareParams(files: [XFile.fromData(utf8.encode(body), mimeType: 'text/plain', name: name)], fileNameOverrides: [name]));
      return null;
    }
    final uri = await FilePicker.saveFile(
      fileName: name,
      initialDirectory: await _startDir(prefs, _exportDirKey, Directory(p.join(scriptsDir.path, 'Exports'))),
      bytes: Uint8List.fromList(utf8.encode(body)),
      mimeType: 'text/plain',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (uri == null) return null;
    final path = uri.toFilePath();
    await prefs.setString(_exportDirKey, p.dirname(path));
    return path;
  }

  static Future<String?> chooseAudio() async {
    final f = await FilePicker.pickFile(type: FileType.audio);
    return f?.path;
  }

  static Future<void> reveal(Directory dir) async {
    await dir.create(recursive: true);
    if (Platform.isMacOS) {
      await Process.run('open', [dir.path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [p.normalize(dir.path)]);
    }
  }
}

/// A script title from an imported file's name: no extension, cut at a word boundary to the title
/// limit. Empty when nothing usable is left, so the first line shows instead.
String titleFromFileName(String fileName) {
  final stem = p.basenameWithoutExtension(fileName).replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  if (stem.length <= SavedScript.maxTitleLength) return stem;
  final cut = stem.substring(0, SavedScript.maxTitleLength);
  final space = cut.lastIndexOf(' ');
  return (space > 8 ? cut.substring(0, space) : cut).trim();
}
