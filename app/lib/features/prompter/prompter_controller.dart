import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/matching/script_tracker.dart';
import '../../core/progress/reading_progress.dart';
import '../../core/script/text.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/audio/audio_input.dart';
import '../../services/audio/reference_clock.dart';
import '../../services/speech/native_speech_recognizer.dart';

/// Voice and Audio mode's recogniser: the platform's own (Android, iOS, macOS, Windows); null elsewhere.
/// A device without one is told so.
final nativeSpeechProvider = Provider<NativeSpeechRecognizer?>(
  (_) => Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows ? NativeSpeechRecognizer() : null,
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

  /// Mobile Voice mode: this device has no on-device speech recognition to follow the reader
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
  PromptControlMode _mode = PromptControlMode.normal;
  ScriptTracker? _tracker;
  StreamSubscription<Object?>? _voiceSub;
  bool _nativeVoice = false;
  final _trackerClock = Stopwatch()..start();
  Timer? _lostTimer;
  static const _lostAfter = Duration(seconds: 4);
  ReferenceClock? _clock;
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
    Stream<Float32List>? externalSamples,
  }) async {
    if (sessionId == _session && mode == _mode) return;
    await _teardown();
    _session = sessionId;
    _mode = mode;
    _wordCount = scriptWords(script).length;
    _tracker = ScriptTracker(scriptWords(script));
    state = PrompterState(resetToken: state.resetToken + 1);
    _externalSamples = externalSamples;
    _audioPath = audioPath;
    if (mode == PromptControlMode.recordedAudio) await _prepareAudio();
  }

  Stream<Float32List>? _externalSamples;
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
        if (clock == null) return;
        // Listening first, so the recogniser is up as the audio starts; if it can't, nothing plays.
        await _startVoice();
        if (!state.playing) return;
        state = state.copyWith(finished: false);
        // just_audio's play() future only completes on pause/end, so don't await it.
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
        await _stopVoice();
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
    final native = ref.read(nativeSpeechProvider);
    state = state.copyWith(voiceUnsupported: false);
    // There is no other recogniser: a device without speech recognition is told so.
    if (native != null && await _safeAvailable(native)) return _startNativeVoice(native);
    return _voiceUnsupported('Speech recognition is not available on this device');
  }

  void _voiceUnsupported(String message) =>
      state = state.copyWith(playing: false, status: message, voiceUnsupported: true);

  Future<bool> _safeAvailable(NativeSpeechRecognizer native) async {
    try {
      return await native.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Voice mode on the platform recogniser: it reports the whole running hypothesis, which
  /// [ScriptTracker] follows on every change. It records the microphone itself.
  Future<void> _startNativeVoice(NativeSpeechRecognizer native) async {
    if (!await _input.hasPermission()) {
      state = state.copyWith(status: 'Microphone access is needed for Voice control');
      return;
    }
    _nativeVoice = true;
    _tracker?.syncTo(state.progress.confirmedWordIndex);
    await _sendBias(native);
    state = state.copyWith(playing: true, status: 'Listening', voiceUnsupported: false);
    // The Record screen records the microphone, so the recogniser may not open it itself (reference: Video mode).
    _voiceSub = native.hypotheses(micFallback: _externalSamples == null, headsetMic: _mode != PromptControlMode.recordedAudio).listen(_onHypothesis, onError: (Object e) {
      final sub = _voiceSub;
      _nativeVoice = false;
      _voiceSub = null;
      unawaited(sub?.cancel());
      if (_mode == PromptControlMode.recordedAudio) unawaited(_clock?.pause());
      if (e is NativeRecognizerUnavailable) {
        // `isAvailable` can be true while the English pack is still missing.
        _voiceUnsupported(e.message);
        return;
      }
      state = state.copyWith(playing: false, status: '$e');
    });
  }

  Future<void> _sendBias(NativeSpeechRecognizer native) async {
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
    _nativeVoice = false;
    await sub.cancel(); // stops the recogniser, which owns its microphone
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
      final native = ref.read(nativeSpeechProvider);
      if (native != null && _nativeVoice) unawaited(_sendBias(native));
    }
  }

  void _clearLost() {
    _lostTimer?.cancel();
    _lostTimer = null;
  }

  // --- Recorded audio --------------------------------------------------------

  /// Only loads the file to play it; following it is the recogniser's job at Play: it listens to the
  /// file through the microphone exactly as it listens to a reader in Voice mode.
  Future<void> _prepareAudio() async {
    final path = _audioPath;
    if (path == null) {
      state = state.copyWith(status: 'Choose an audio file');
      return;
    }
    state = state.copyWith(preparing: true, status: 'Loading audio…');
    try {
      final clock = ref.read(referenceClockFactoryProvider)(audible: true);
      await clock.load(path);
      _clock = clock;
      clock.completed.listen((_) async {
        // The recogniser is still finishing the last words.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (_clock != clock || !state.playing || clock.isPlaying) return;
        await pause();
        state = state.copyWith(finished: true, status: 'Finished');
      });
      state = state.copyWith(preparing: false, status: 'Ready — press Play');
    } catch (_) {
      state = state.copyWith(preparing: false, status: 'Could not load this audio file');
    }
  }

  Future<void> _teardown() async {
    _clearLost();
    await _stopVoice();
    await _clock?.dispose();
    _clock = null;
  }
}

final prompterProvider = NotifierProvider<PrompterController, PrompterState>(PrompterController.new);
