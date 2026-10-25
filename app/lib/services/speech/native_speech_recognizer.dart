import 'package:flutter/services.dart';

/// The platform speech recogniser: Android's `SpeechRecognizer` or Apple's `SFSpeechRecognizer` (iOS, iPadOS,
/// macOS), on-device where the device has it and otherwise the system one (which may use the network), reporting partial results as the
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
  ///
  /// [headsetMic]: macOS opens the microphone itself and, when set, prefers a connected USB or Bluetooth headset
  /// over the built-in one (Audio mode must hear the speaker, so it clears this). Android and iOS choose the
  /// microphone in the camera plugin and ignore it.
  Stream<SpeechHypothesis> hypotheses({bool micFallback = true, bool headsetMic = true}) =>
      _events.receiveBroadcastStream({'micFallback': micFallback, 'headset': headsetMic}).map((e) {
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

/// The recogniser's running text for the current utterance. [isFinal] ends the
/// utterance (a result, or the recogniser restarting without one).
class SpeechHypothesis {
  const SpeechHypothesis(this.text, {required this.isFinal});
  final String text;
  final bool isFinal;
}

/// Speech recognition can't run; [message] tells the reader why.
class SpeechUnavailable implements Exception {
  SpeechUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}
