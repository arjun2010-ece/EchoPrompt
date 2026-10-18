import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Timeline for Recorded-audio mode. Either plays the file ([AudiblePlayback])
/// or advances silently on the file's word timeline ([SilentClock]) so a
/// recording isn't polluted by speaker output (plan §10.2).
abstract class ReferenceClock {
  /// Loads the file and returns its duration in seconds.
  Future<double> load(String path);
  Duration get position;
  bool get isPlaying;
  Future<void> play();
  Future<void> pause();
  Future<void> seekToStart();
  Stream<void> get completed;
  Future<void> dispose();
}

class AudiblePlayback implements ReferenceClock {
  final _player = AudioPlayer();

  @override
  Future<double> load(String path) async {
    final d = await _player.setFilePath(path);
    return (d ?? Duration.zero).inMilliseconds / 1000.0;
  }

  @override
  Duration get position => _player.position;
  @override
  bool get isPlaying => _player.playing;
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seekToStart() => _player.seek(Duration.zero);
  @override
  Stream<void> get completed =>
      _player.processingStateStream.where((s) => s == ProcessingState.completed);
  @override
  Future<void> dispose() => _player.dispose();
}

class SilentClock implements ReferenceClock {
  SilentClock({required this.durationOf});

  /// Reads the file's duration without playing it.
  final Future<double> Function(String path) durationOf;
  final _sw = Stopwatch();
  Duration _base = Duration.zero;
  double _duration = 0;
  final _done = StreamController<void>.broadcast();
  Timer? _timer;

  @override
  Future<double> load(String path) async => _duration = await durationOf(path);

  @override
  Duration get position => _base + _sw.elapsed;
  @override
  bool get isPlaying => _sw.isRunning;

  @override
  Future<void> play() async {
    _sw.start();
    _timer?.cancel();
    final remaining = Duration(milliseconds: (_duration * 1000).round()) - position;
    _timer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _sw.stop();
      _done.add(null);
    });
  }

  @override
  Future<void> pause() async {
    _base += _sw.elapsed;
    _sw
      ..stop()
      ..reset();
    _timer?.cancel();
  }

  @override
  Future<void> seekToStart() async {
    await pause();
    _base = Duration.zero;
  }

  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _done.close();
  }
}
