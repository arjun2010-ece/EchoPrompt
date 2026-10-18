import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Locates the English model files. The model is too large for git: run
/// `tools/fetch_models.sh` before building so it is bundled as an asset under
/// `assets/models/en/`; it's copied to app support on first use.
class ModelStore {
  static const _files = [
    'online/encoder.int8.onnx',
    'online/decoder.onnx',
    'online/joiner.int8.onnx',
    'online/tokens.txt',
    'offline/encoder.int8.onnx',
    'offline/decoder.onnx',
    'offline/joiner.int8.onnx',
    'offline/tokens.txt',
  ];

  /// Returns the directory holding the model files, or null if missing.
  static Future<Directory?> english() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'models', 'en'));
    if (_complete(dir)) return dir;
    try {
      for (final f in _files) {
        final data = await rootBundle.load('assets/models/en/$f');
        final out = File(p.join(dir.path, f));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
    } on FlutterError {
      return null; // model not bundled
    }
    return _complete(dir) ? dir : null;
  }

  static bool _complete(Directory d) => _files.every((f) => File(p.join(d.path, f)).existsSync());
}
