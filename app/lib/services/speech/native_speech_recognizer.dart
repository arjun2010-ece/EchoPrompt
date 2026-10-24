import 'package:flutter/services.dart';

import 'speech_engine.dart';

/// The platform speech recogniser: Android's `SpeechRecognizer` or iOS's `SFSpeechRecognizer`, on-device where
/// the phone has it and otherwise the system one (which may use the network), reporting partial results as the
/// speaker talks. It reads our own microphone capture (the one a take records), except on Android below 13,
/// where it opens the microphone itself. [isAvailable] is false when the phone has no recogniser at all.
class NativeSpeechRecognizer {
  static const _method = MethodChannel('com.echoprompter/speech');
  static const _events = EventChannel('com.echoprompter/speech/events');

  Future<bool> isAvailable() async => await _method.invokeMethod<bool>('isAvailable') ?? false;

  /// Words the recogniser should favour; read when each listening session starts.
  Future<void> setBias(List<String> words) => _method.invokeMethod<void>('setBias', words);

  /// Listening runs while this stream has a listener. [micFallback]: if our microphone capture can't be
  /// recognised, the recogniser may open the microphone itself (not while a camera screen records it).
  Stream<SpeechHypothesis> hypotheses({bool micFallback = true}) =>
      _events.receiveBroadcastStream({'micFallback': micFallback}).map((e) {
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

/// The phone has no recogniser Voice mode can use for English; the reader is told so.
class NativeRecognizerUnavailable extends SpeechUnavailable {
  NativeRecognizerUnavailable(super.message);
}
