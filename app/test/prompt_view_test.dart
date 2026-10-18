import 'package:echoprompt/core/settings/prompt_settings.dart';
import 'package:echoprompt/features/prompter/prompt_view.dart';
import 'package:echoprompt/features/prompter/prompter_controller.dart';
import 'package:echoprompt/services/providers.dart';
import 'package:echoprompt/services/storage/script_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

void main() {
  testWidgets('PromptView scrolls in Normal mode and highlights in Voice progress', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final lib = ScriptLibrary(Directory.systemTemp, prefs);
    final long = List.generate(300, (i) => 'word$i').join(' ');
    final c = ProviderContainer(overrides: [
      prefsProvider.overrideWithValue(prefs),
      libraryProvider.overrideWithValue(lib),
    ]);
    addTearDown(c.dispose);
    c.read(studioProvider.notifier).setScript(long);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: PromptView())),
    ));
    final p = c.read(prompterProvider.notifier);
    await p.begin(sessionId: 1, script: long, mode: PromptControlMode.normal);
    await p.play();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.controller!.offset, greaterThan(0));

    // A new session (begin) resets scroll.
    await p.begin(sessionId: 2, script: long, mode: PromptControlMode.normal);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView)).controller!.offset, 0);
    await p.pause();
    await tester.pump();
  });
}
