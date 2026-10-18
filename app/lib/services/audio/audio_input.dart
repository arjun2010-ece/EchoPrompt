import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../speech/speech_engine.dart';

/// 16 kHz mono float microphone samples. Opening the mic triggers an OS
/// permission prompt, so [start] must only ever be called for Voice mode
/// (Normal mode never touches the microphone; see prompter_controller_test).
abstract class AudioInput {
  Future<bool> hasPermission();
  Stream<Float32List> start();
  Future<void> stop();
}

class RecordAudioInput implements AudioInput {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Stream<Float32List> start() async* {
    final bytes = await _recorder.startStream(
      const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
    );
    yield* bytes.map(pcm16ToFloat);
  }

  @override
  Future<void> stop() async {
    if (await _recorder.isRecording()) await _recorder.stop();
  }
}
