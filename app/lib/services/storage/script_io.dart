import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../platform.dart';

/// Script import/export. Mobile exports go through the share sheet, which on
/// Android covers the Storage Access Framework and on iOS the Files app.
class ScriptIO {
  static Future<String?> importText() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['txt', 'md']);
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Future<void> exportText(String title, String body) async {
    final name = '${title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim().isEmpty ? 'Script' : title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim()}.txt';
    if (isMobile) {
      await SharePlus.instance.share(ShareParams(files: [XFile.fromData(utf8.encode(body), mimeType: 'text/plain', name: name)], fileNameOverrides: [name]));
    } else {
      await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(body)),
        mimeType: 'text/plain',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
    }
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
