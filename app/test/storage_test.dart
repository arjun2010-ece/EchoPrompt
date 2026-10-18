import 'dart:io';

import 'package:echoprompt/core/script/saved_script.dart';
import 'package:echoprompt/core/settings/prompt_settings.dart';
import 'package:echoprompt/services/storage/migration.dart';
import 'package:echoprompt/services/storage/script_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  late SharedPreferences prefs;
  late ScriptLibrary lib;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('echoprompt_test');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    lib = ScriptLibrary(dir, prefs);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  SavedScript script(String id, String body) => SavedScript(id: id, body: body, savedAt: DateTime.now());

  test('save derives file name from first line and numbers duplicates', () async {
    var h = await lib.save([], script('a', 'Hello world\nbody'));
    h = await lib.save(h, script('b', 'Hello world\nother'));
    expect(h.map((s) => s.fileName), ['Hello world 2.txt', 'Hello world.txt']);
    expect(File('${dir.path}/Hello world.txt').readAsStringSync(), 'Hello world\nbody');
  });

  test('history keeps at most 20 and reloads from disk', () async {
    var h = <SavedScript>[];
    for (var i = 0; i < 22; i++) {
      h = await lib.save(h, script('$i', 'Script $i'));
    }
    expect(h.length, 20);
    expect(lib.load().length, 20);
    expect(lib.load().first.body, 'Script 21');
  });

  test('delete removes file and entry', () async {
    final h = await lib.save([], script('a', 'Bye'));
    final after = await lib.delete(h, h.first);
    expect(after, isEmpty);
    expect(File('${dir.path}/Bye.txt').existsSync(), isFalse);
  });

  test('fingerprint ignores whitespace differences', () {
    expect(script('a', 'one  two\n').fingerprint, script('b', 'one two').fingerprint);
  });

  test('POC migration rebuilds history from txt files once', () async {
    File('${dir.path}/Old one.txt').writeAsStringSync('Old one');
    final s = await migrateFromPoc(
      prefs: prefs,
      library: lib,
      current: const PromptSettings(),
      legacyDefaults: {'placement': 'notch', 'corner': 'bottomLeft', 'hideFromCapture': false},
    );
    expect(lib.load().single.body, 'Old one');
    expect(s!.placement, PromptPlacement.notch);
    expect(s.corner, PromptCorner.bottomLeft);
    expect(s.hideFromCapture, isFalse);
    expect(
      await migrateFromPoc(prefs: prefs, library: lib, current: const PromptSettings(), legacyDefaults: {}),
      isNull,
    );
  });

  test('settings round-trip and clamp font size', () {
    final s = const PromptSettings().copyWith(fontSize: 500, mirror: true, mode: PromptControlMode.voice);
    final back = PromptSettings.fromJson(s.toJson());
    expect(back.fontSize, 110);
    expect(back.mirror, isTrue);
    expect(back.mode, PromptControlMode.voice);
  });
}
