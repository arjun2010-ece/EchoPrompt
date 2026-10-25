import 'dart:io';

import 'native_speech_recognizer.dart';

/// Something the reader has to allow or turn on before Voice and Audio mode can work, and how to get there.
class SpeechRequirement {
  const SpeechRequirement({required this.title, required this.message, required this.openSettings});
  final String title;
  final String message;
  final Future<void> Function() openSettings;
}

/// The first unmet requirement for Voice and Audio mode on this desktop, or null if there is none (or it can't
/// be told, in which case the recogniser reports any real problem itself).
Future<SpeechRequirement?> unmetSpeechRequirement() async {
  // Windows needs nothing: its on-device recogniser works without any Settings switch.
  if (Platform.isMacOS) {
    try {
      final r = await NativeSpeechRecognizer().readiness();
      bool blocked(String? s) => s == 'denied' || s == 'restricted';
      if (blocked(r['speech'])) {
        return SpeechRequirement(
          title: 'Allow speech recognition',
          message: 'Voice and Audio mode need Speech Recognition access. Turn it on for EchoPrompter in '
              'System Settings > Privacy & Security > Speech Recognition.',
          openSettings: () => _open('x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition'),
        );
      }
      if (blocked(r['mic'])) {
        return SpeechRequirement(
          title: 'Allow microphone access',
          message: 'Voice and Audio mode listen through the microphone. Turn it on for EchoPrompter in '
              'System Settings > Privacy & Security > Microphone.',
          openSettings: () => _open('x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'),
        );
      }
      if (r['dictation'] == 'off') {
        return SpeechRequirement(
          title: 'Turn on Dictation',
          message: 'Voice and Audio mode use macOS speech recognition, which needs Dictation turned on in '
              'System Settings > Keyboard.',
          openSettings: () => _open('x-apple.systempreferences:com.apple.Keyboard-Settings.extension'),
        );
      }
    } catch (_) {}
  }
  return null;
}

Future<void> _open(String url) async {
  try {
    await Process.run('open', [url]);
  } catch (_) {}
}
