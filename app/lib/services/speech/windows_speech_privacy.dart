import 'dart:io';

/// Windows' "Online speech recognition" switch (Settings > Privacy & security > Speech). Windows' dictation
/// recogniser refuses to run without it, and an app can't turn it on. If the setting can't be read this says
/// it is on, so the recogniser gets to report any real problem itself.
Future<bool> onlineSpeechRecognitionOn() async {
  try {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy',
      '/v',
      'HasAccepted',
    ]);
    // No value yet means it was never turned on.
    return r.exitCode == 0 && RegExp(r'0x1\b').hasMatch('${r.stdout}');
  } catch (_) {
    return true;
  }
}

/// Opens that page of Windows Settings.
Future<void> openOnlineSpeechSettings() async {
  try {
    await Process.run('explorer', ['ms-settings:privacy-speech']);
  } catch (_) {}
}
