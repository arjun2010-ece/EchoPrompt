import 'package:record/record.dart';

/// The microphone permission check for Voice and Audio mode. The recogniser opens the
/// microphone itself; this only asks the OS for access, and so must only be used for those
/// modes (Normal mode never touches the microphone; see prompter_controller_test).
abstract class AudioInput {
  Future<bool> hasPermission();
}

class RecordAudioInput implements AudioInput {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();
}
