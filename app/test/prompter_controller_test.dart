import 'package:echoprompter/core/settings/prompt_settings.dart';
import 'package:echoprompter/features/prompter/prompter_controller.dart';
import 'package:echoprompter/services/audio/audio_input.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeInput implements AudioInput {
  int permissionChecks = 0;
  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    return true;
  }
}

void main() {
  late FakeInput input;
  late ProviderContainer c;

  setUp(() {
    input = FakeInput();
    c = ProviderContainer(overrides: [
      audioInputProvider.overrideWithValue(input),
    ]);
  });
  tearDown(() => c.dispose());

  test('Normal mode never touches the microphone', () async {
    final p = c.read(prompterProvider.notifier);
    await p.begin(sessionId: 1, script: 'one two three', mode: PromptControlMode.normal);
    await p.play();
    await p.pause();
    await p.restart();
    expect(input.permissionChecks, 0);
  });

  test('a new session id resets progress', () async {
    final p = c.read(prompterProvider.notifier);
    await p.begin(sessionId: 1, script: 'welcome to the show', mode: PromptControlMode.normal);
    p.seekTo(0);
    expect(c.read(prompterProvider).progress.confirmedWordIndex, 0);
    await p.begin(sessionId: 2, script: 'welcome to the show', mode: PromptControlMode.normal);
    expect(c.read(prompterProvider).progress.confirmedWordIndex, -1);
  });
}
