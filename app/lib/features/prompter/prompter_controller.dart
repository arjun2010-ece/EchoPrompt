import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/matching/audio_aligner.dart';
import '../../core/matching/script_tracker.dart';
import '../../core/matching/voice_matcher.dart';
import '../../core/progress/reading_progress.dart';
import '../../core/script/text.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/audio/audio_input.dart';
import '../../services/audio/reference_clock.dart';
import '../../services/speech/android_speech_recognizer.dart';
import '../../services/speech/sherpa_speech_engine.dart';
import '../../services/speech/speech_engine.dart';

final speechEngineProvider = Provider<SpeechEngine>((ref) {
  final e = SherpaSpeechEngine();
  ref.onDispose(e.dispose);
  return e;
});

/// Voice mode's recogniser on Android; null elsewhere. Used only when the device has an
/// on-device recogniser, otherwise Voice mode runs on [speechEngineProvider].
final androidSpeechProvider = Provider<AndroidSpeechRecognizer?>(
  (_) => Platform.isAndroid ? AndroidSpeechRecognizer() : null,
);
final audioInputProvider = Provider<AudioInput>((_) => RecordAudioInput());

/// Builds the clock for a take; overridden in tests.
final referenceClockFactoryProvider =
    Provider<ReferenceClock Function({required bool audible})>((ref) {
      return ({required bool audible}) =>
          audible ? AudiblePlayback() : SilentClock(durationOf: (path) async {
            final c = AudiblePlayback();
            try {
              return await c.load(path);
            } finally {
              await c.dispose();
            }
          });
    });

class PrompterState {
  const PrompterState({
    this.progress = PromptReadingProgress.inactive,
    this.playing = false,
    this.preparing = false,
    this.status = '',
    this.finished = false,
    this.lost = false,
    this.voiceUnsupported = false,
    this.resetToken = 0,
  });
  final PromptReadingProgress progress;
  final bool playing;
  final bool preparing;
  final String status;
  final bool finished;

  /// Voice mode: speech is being heard but has not matched the script for a
  /// few seconds. Cleared as soon as the highlight moves.
  final bool lost;

  /// Android Voice mode: this device has no on-device speech recognition to follow the reader
  /// with. The Read and Record screens tell the reader once each time this turns on.
  final bool voiceUnsupported;

  /// Bumped by [PrompterController.begin] and restart; the text surface resets
  /// its scroll position when it changes.
  final int resetToken;

  PrompterState copyWith({
    PromptReadingProgress? progress,
    bool? playing,
    bool? preparing,
    String? status,
    bool? finished,
    bool? lost,
    bool? voiceUnsupported,
    int? resetToken,
  }) => PrompterState(
    progress: progress ?? this.progress,
    playing: playing ?? this.playing,
    preparing: preparing ?? this.preparing,
    status: status ?? this.status,
    finished: finished ?? this.finished,
    lost: lost ?? this.lost,
    voiceUnsupported: voiceUnsupported ?? this.voiceUnsupported,
    resetToken: resetToken ?? this.resetToken,
  );
}

/// Drives one prompting session. [begin] is called with a new session id on
/// every Start; that is the only signal that resets progress and playback.
class PrompterController extends Notifier<PrompterState> {
  late final AudioInput _input;
  int _session = -1;
  String _script = '';
  PromptControlMode _mode = PromptControlMode.normal;
  VoiceMatcher? _matcher;
  ScriptTracker? _tracker;
  StreamSubscription<Object?>? _voiceSub;
  bool _nativeVoice = false;
  final _trackerClock = Stopwatch()..start();
  Timer? _clockTimer;
  Timer? _lostTimer;
  static const _lostAfter = Duration(seconds: 4);
  ReferenceClock? _clock;
  List<TimedWord> _timed = const [];
  double _audioDuration = 0;
  int _wordCount = 0;

  @override
  PrompterState build() {
    _input = ref.read(audioInputProvider);
    ref.onDispose(_teardown);
    return const PrompterState();
  }

  int get wordCount => _wordCount;

  Future<void> begin({
    required int sessionId,
    required String script,
    required PromptControlMode mode,
    String? audioPath,
    bool audible = true,
    Stream<Float32List>? externalSamples,
  }) async {
    if (sessionId == _session && mode == _mode) return;
    await _teardown();
    _session = sessionId;
    _script = script;
    _mode = mode;
    _wordCount = scriptWords(script).length;
    _matcher = VoiceMatcher(script);
    _tracker = ScriptTracker(scriptWords(script));
    state = PrompterState(resetToken: state.resetToken + 1);
    _externalSamples = externalSamples;
    _audible = audible;
    _audioPath = audioPath;
    if (mode == PromptControlMode.recordedAudio) await _prepareAudio();
  }

  /// Loads the speech model before Voice mode's Start, so Start doesn't spend its first
  /// seconds (and the first spoken words) on it. Loading blocks the UI thread briefly, so
  /// call it once the screen is on display, not while its route is still animating in.
  /// Android's platform recogniser needs none: like the reference, it is created at Start.
  void warmUpVoice() {
    if (ref.read(androidSpeechProvider) == null) _warmUpSherpa();
  }

  void _warmUpSherpa() {
    final engine = ref.read(speechEngineProvider);
    if (engine is SherpaSpeechEngine) unawaited(engine.warmUp().catchError((Object _) {}));
  }

  Stream<Float32List>? _externalSamples;
  bool _audible = true;
  String? _audioPath;

  Future<void> togglePlay() => state.playing ? pause() : play();

  Future<void> play() async {
    switch (_mode) {
      case PromptControlMode.normal:
        state = state.copyWith(playing: true, finished: false);
      case PromptControlMode.voice:
        await _startVoice();
      case PromptControlMode.recordedAudio:
        final clock = _clock;
        if (clock == null || _timed.isEmpty) return;
        // just_audio's play() future only completes on pause/end, so don't await it
        // before publishing the playing state.
        _clockTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _tickClock());
        state = state.copyWith(playing: true, finished: false, status: 'Playing');
        unawaited(clock.play());
    }
  }

  Future<void> pause() async {
    switch (_mode) {
      case PromptControlMode.normal:
        break;
      case PromptControlMode.voice:
        await _stopVoice();
      case PromptControlMode.recordedAudio:
        await _clock?.pause();
        _clockTimer?.cancel();
        _clockTimer = null;
    }
    _clearLost();
    state = state.copyWith(playing: false, lost: false);
  }

  Future<void> restart() async {
    final wasMode = _mode;
    await pause();
    state = PrompterState(preparing: state.preparing, status: state.status, resetToken: state.resetToken + 1);
    if (wasMode == PromptControlMode.recordedAudio) await _clock?.seekToStart();
  }

  /// Jump to a tapped word (Voice/Audio: the matcher continues from there).
  void seekTo(int index) {
    if (index < 0 || index >= _wordCount) return;
    _clearLost();
    state = state.copyWith(
      lost: false,
      progress: PromptReadingProgress.synchronized(
        confirmed: index,
        predicted: index + 1 < _wordCount ? index + 1 : null,
      ),
    );
  }

  /// Normal mode reached the end of the script.
  void markFinished() => state = state.copyWith(playing: false, finished: true);

  // --- Voice ---------------------------------------------------------------

  Future<void> _startVoice() async {
    final native = ref.read(androidSpeechProvider);
    if (native != null) {
      // Android has no other recogniser: a device without on-device speech recognition is told so.
      state = state.copyWith(voiceUnsupported: false);
      if (await _safeAvailable(native)) return _startNativeVoice(native);
      return _voiceUnsupported('Speech recognition is not available on this device');
    }
    final engine = ref.read(speechEngineProvider);
    try {
      await engine.init();
      Stream<Float32List> samples;
      if (_externalSamples != null) {
        samples = _externalSamples!;
      } else {
        final input = _input;
        if (!await input.hasPermission()) {
          state = state.copyWith(status: 'Microphone access is needed for Voice control');
          return;
        }
        samples = input.start();
      }
      state = state.copyWith(playing: true, status: 'Listening');
      void failed(Object e) => state = state.copyWith(playing: false, status: '$e');
      _voiceSub = engine.listen(samples).listen(_onWords, onError: failed);
    } on SpeechUnavailable catch (e) {
      state = state.copyWith(playing: false, status: e.message);
    }
  }

  void _voiceUnsupported(String message) =>
      state = state.copyWith(playing: false, status: message, voiceUnsupported: true);

  Future<bool> _safeAvailable(AndroidSpeechRecognizer native) async {
    try {
      return await native.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Voice mode on the platform recogniser: it reports the whole running hypothesis, which
  /// [ScriptTracker] follows on every change. It records the microphone itself.
  Future<void> _startNativeVoice(AndroidSpeechRecognizer native) async {
    if (!await _input.hasPermission()) {
      state = state.copyWith(status: 'Microphone access is needed for Voice control');
      return;
    }
    _nativeVoice = true;
    _tracker?.syncTo(state.progress.confirmedWordIndex);
    await _sendBias(native);
    state = state.copyWith(playing: true, status: 'Listening', voiceUnsupported: false);
    // The Record screen records the microphone, so the recogniser may not open it itself (reference: Video mode).
    _voiceSub = native.hypotheses(micFallback: _externalSamples == null).listen(_onHypothesis, onError: (Object e) {
      final sub = _voiceSub;
      _nativeVoice = false;
      _voiceSub = null;
      unawaited(sub?.cancel());
      if (e is NativeRecognizerUnavailable) {
        // `isAvailable` can be true while the English pack is still missing.
        _voiceUnsupported(e.message);
        return;
      }
      state = state.copyWith(playing: false, status: '$e');
    });
  }

  Future<void> _sendBias(AndroidSpeechRecognizer native) async {
    final words = _tracker?.biasingWords();
    if (words == null) return;
    try {
      await native.setBias(words);
    } catch (_) {}
  }

  Future<void> _stopVoice() async {
    // Only touch the microphone if Voice mode actually opened it.
    final sub = _voiceSub;
    if (sub == null) return;
    _voiceSub = null;
    if (_nativeVoice) {
      _nativeVoice = false;
      await sub.cancel(); // stops the recogniser, which owns its microphone
      return;
    }
    // The recognizer's generator only finishes cancelling once the sample
    // stream ends, so don't await it before closing the microphone.
    unawaited(sub.cancel());
    if (_externalSamples == null) await _input.stop();
  }

  void _onWords(List<String> words) {
    final current = state.progress.confirmedWordIndex;
    final next = _matcher!.follow(words, current);
    if (next == current) {
      // Speech that keeps not matching means the reader is out of step.
      if (words.isNotEmpty && !state.lost) _lostTimer ??= Timer(_lostAfter, () => state = state.copyWith(lost: true));
      return;
    }
    _clearLost();
    state = state.copyWith(
      progress: PromptReadingProgress.synchronized(
        confirmed: next,
        predicted: next + 1 < _wordCount ? next + 1 : null,
      ),
      lost: false,
      finished: next >= _wordCount - 1,
    );
  }

  /// Every recogniser result goes to the tracker, as the reference does (`ud.q`); blank ones carry nothing.
  void _onHypothesis(SpeechHypothesis h) {
    final tracker = _tracker;
    if (tracker == null) return;
    if (h.text.trim().isNotEmpty) {
      tracker.syncTo(state.progress.confirmedWordIndex);
      final moved = tracker.update(h.text, _trackerClock.elapsedMilliseconds);
      if (moved == null) {
        // Speech that keeps not matching means the reader is out of step.
        if (!state.lost) _lostTimer ??= Timer(_lostAfter, () => state = state.copyWith(lost: true));
      } else {
        _clearLost();
        final confirmed = tracker.lastMatched;
        state = state.copyWith(
          progress: PromptReadingProgress.synchronized(
            confirmed: confirmed,
            predicted: confirmed + 1 < _wordCount ? confirmed + 1 : null,
          ),
          lost: false,
          finished: moved >= _wordCount,
        );
      }
    }
    if (h.isFinal) {
      tracker.endUtterance();
      final native = ref.read(androidSpeechProvider);
      if (native != null && _nativeVoice) unawaited(_sendBias(native));
    }
  }

  void _clearLost() {
    _lostTimer?.cancel();
    _lostTimer = null;
  }

  // --- Recorded audio --------------------------------------------------------

  Future<void> _prepareAudio() async {
    final path = _audioPath;
    if (path == null) {
      state = state.copyWith(status: 'Choose an audio file');
      return;
    }
    state = state.copyWith(preparing: true, status: 'Synchronizing audio…');
    try {
      final engine = ref.read(speechEngineProvider);
      await engine.init();
      final clock = ref.read(referenceClockFactoryProvider)(audible: _audible);
      _audioDuration = await clock.load(path);
      final segments = await engine.transcribeFile(path);
      final timed = alignTranscript(
        tokens: tokensFromSegments(segments),
        segments: segments,
        script: _script,
        audioDuration: _audioDuration,
      );
      _clock = clock;
      clock.completed.listen((_) async {
        _clockTimer?.cancel();
        _clockTimer = null;
        state = state.copyWith(playing: false, finished: true, status: 'Finished');
      });
      _timed = timed;
      state = state.copyWith(
        preparing: false,
        status: timed.isEmpty ? 'Could not match audio to this script' : 'Ready — press Play',
      );
    } on SpeechUnavailable catch (e) {
      state = state.copyWith(preparing: false, status: e.message);
    } catch (_) {
      state = state.copyWith(preparing: false, status: 'Could not synchronize this audio file');
    }
  }

  void _tickClock() {
    final clock = _clock;
    if (clock == null) return;
    final elapsed = clock.position.inMilliseconds / 1000.0;
    final ceiling = pacingCeiling(
      elapsed: elapsed,
      audioDuration: _audioDuration,
      scriptWordCount: _wordCount,
    );
    final word = currentWordAt(timed: _timed, elapsed: elapsed, ceiling: ceiling);
    if (word != null && word > state.progress.confirmedWordIndex) {
      state = state.copyWith(progress: PromptReadingProgress.synchronized(confirmed: word));
    }
  }

  Future<void> _teardown() async {
    _clearLost();
    _clockTimer?.cancel();
    _clockTimer = null;
    await _stopVoice();
    await _clock?.dispose();
    _clock = null;
    _timed = const [];
  }
}

final prompterProvider = NotifierProvider<PrompterController, PrompterState>(PrompterController.new);
