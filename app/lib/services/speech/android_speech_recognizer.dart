import 'package:flutter/services.dart';

import 'speech_engine.dart';

/// The recogniser's running text for the current utterance. [isFinal] ends the
/// utterance (a result, or the recogniser restarting without one).
class SpeechHypothesis {
  const SpeechHypothesis(this.text, {required this.isFinal});
  final String text;
  final bool isFinal;
}

/// Android's on-device `SpeechRecognizer` (API 31+), which reports partial results as the
/// speaker talks. It listens to the microphone itself. Never uploads audio: when no
/// on-device recogniser is installed [isAvailable] is false and callers fall back.
class AndroidSpeechRecognizer {
  static const _method = MethodChannel('com.echoprompt/speech');
  static const _events = EventChannel('com.echoprompt/speech/events');

  Future<bool> isAvailable() async => await _method.invokeMethod<bool>('isAvailable') ?? false;

  /// Starts binding the recogniser service so the first Start isn't spent on it.
  Future<void> warmUp() => _method.invokeMethod<void>('warmUp');

  /// Words the recogniser should favour; read when each listening session starts.
  Future<void> setBias(List<String> words) => _method.invokeMethod<void>('setBias', words);

  /// Listening runs while this stream has a listener.
  Stream<SpeechHypothesis> hypotheses() => _events.receiveBroadcastStream().map((e) {
    final m = e as Map;
    return SpeechHypothesis(m['text'] as String, isFinal: m['final'] as bool);
  }).handleError((Object e) {
    if (e is PlatformException) {
      final message = e.message ?? e.code;
      throw e.code == 'language' || e.code == 'unavailable' ? NativeRecognizerUnavailable(message) : SpeechUnavailable(message);
    }
    throw e;
  });
}

/// The device has no usable on-device recogniser (for instance its English pack isn't
/// downloaded yet), so Voice mode should use another engine.
class NativeRecognizerUnavailable extends SpeechUnavailable {
  NativeRecognizerUnavailable(super.message);
}
