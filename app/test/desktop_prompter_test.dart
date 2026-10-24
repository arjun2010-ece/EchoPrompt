import 'dart:io';

import 'package:echoprompter/core/settings/prompt_settings.dart';
import 'package:echoprompter/features/prompter/desktop_prompter_screen.dart';
import 'package:echoprompter/services/providers.dart';
import 'package:echoprompter/services/storage/script_library.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final (name, placement, size) in [
    ('full', PromptPlacement.floating, const Size(900, 360)),
    ('compact', PromptPlacement.corner, const Size(420, 240)),
    ('notch', PromptPlacement.notch, const Size(560, 190)),
  ]) {
    testWidgets('$name layout builds without errors and controls respond', (t) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.echoprompter/window'),
        (c) async {
          calls.add(c.method);
          return c.method == 'hasHardwareNotch' || c.method == 'supportsCaptureHiding' ? true : null;
        },
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        prefsProvider.overrideWithValue(prefs),
        libraryProvider.overrideWithValue(ScriptLibrary(Directory.systemTemp, prefs)),
      ]);
      addTearDown(c.dispose);
      c.read(settingsProvider.notifier).update((s) => s.copyWith(placement: placement));
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      // Exactly like main.dart: no Scaffold above the prompter.
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(debugShowCheckedModeBanner: false, home: DesktopPrompterScreen()),
      ));
      await t.pump(const Duration(milliseconds: 100));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(size.center(Offset.zero));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);

      // Play via the keyboard shortcut like the Swift app.
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pump(const Duration(milliseconds: 200));
      expect(t.takeException(), isNull);
      expect(calls, contains('enterPrompter'));
      await t.pumpWidget(const SizedBox());
    });
  }
}
