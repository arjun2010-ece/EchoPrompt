import 'dart:async';
import 'dart:typed_data';

import 'package:echoprompter/core/matching/audio_aligner.dart';
import 'package:echoprompter/core/settings/prompt_settings.dart';
import 'package:echoprompter/features/prompter/prompter_controller.dart';
import 'package:echoprompter/services/audio/audio_input.dart';
import 'package:echoprompter/services/speech/speech_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeInput implements AudioInput {
  int starts = 0, permissionChecks = 0;
  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    return true;
  }

  @override
  Stream<Float32List> start() {
    starts++;
    return const Stream.empty();
  }

  @override
  Future<void> stop() async {}
}

class FakeEngine implements SpeechEngine {
  final words = StreamController<List<String>>();
  @override
  Future<void> init() async {}
  @override
  Stream<List<String>> listen(Stream<Float32List> samples) => words.stream;
  @override
  Future<List<TranscriptSegment>> transcribeFile(String path) async => [];
  @override
  Future<void> dispose() async {}
}

void main() {
  late FakeInput input;
  late FakeEngine engine;
  late ProviderContainer c;

  setUp(() {
    input = FakeInput();
    engine = FakeEngine();
    c = ProviderContainer(overrides: [
      audioInputProvider.overrideWithValue(input),
      speechEngineProvider.overrideWithValue(engine),
    ]);
  });
  tearDown(() => c.dispose());

  test('Normal mode never touches the microphone', () async {
    final p = c.read(prompterProvider.notifier);
    await p.begin(sessionId: 1, script: 'one two three', mode: PromptControlMode.normal);
    await p.play();
    await p.pause();
    await p.restart();
    expect(input.starts, 0);
    expect(input.permissionChecks, 0);
  });

  test('Voice mode follows recognised words', () async {
    final p = c.read(prompterProvider.notifier);
    await p.begin(sessionId: 1, script: 'welcome to the show', mode: PromptControlMode.voice);
    await p.play();
    expect(input.starts, 1);
    engine.words.add(['welcome', 'to']);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(prompterProvider).progress.confirmedWordIndex, 1);
  });

  test('a new session id resets progress', () async {
    final p = c.read(prompterProvider.notifier);
    await p.begin(sessionId: 1, script: 'welcome to the show', mode: PromptControlMode.voice);
    await p.play();
    engine.words.add(['welcome']);
    await Future<void>.delayed(Duration.zero);
    await p.begin(sessionId: 2, script: 'welcome to the show', mode: PromptControlMode.voice);
    expect(c.read(prompterProvider).progress.confirmedWordIndex, -1);
  });
}
