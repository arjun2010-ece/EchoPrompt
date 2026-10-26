import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/sections.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/providers.dart';
import 'prompter_controller.dart';

/// Whole-number percent read, from the word the presenter has reached.
int readingPercent(WidgetRef ref) {
  final mode = ref.watch(settingsProvider.select((s) => s.mode));
  final finished = ref.watch(prompterProvider.select((p) => p.finished));
  final tracked = ref.watch(prompterProvider.select((p) => p.progress.confirmedWordIndex));
  final scrolled = ref.watch(readingWordProvider);
  final words = ref.read(prompterProvider.notifier).wordCount;
  if (finished) return 100;
  if (words <= 1) return 0;
  final index = mode == PromptControlMode.normal ? scrolled : math.max(tracked, 0);
  return (100 * index / (words - 1)).floor().clamp(0, 100);
}

String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// `Demo · 3 of 4  ·  42%  ·  1:10 elapsed  ·  ~1:35 left`. It is a widget of its own so a clock tick
/// rebuilds this line and never the script text. Elapsed counts only while the prompter is playing,
/// and starts over with Restart and with each new session.
class ProgressLine extends ConsumerStatefulWidget {
  const ProgressLine({super.key, this.style});
  final TextStyle? style;

  @override
  ConsumerState<ProgressLine> createState() => _ProgressLineState();
}

class _ProgressLineState extends ConsumerState<ProgressLine> {
  Timer? _timer;
  Duration _banked = Duration.zero;
  DateTime? _since;

  /// Recent (elapsed seconds, word index) samples, for how fast Voice mode is moving.
  final _samples = <(double, int)>[];

  Duration get _elapsed => _banked + (_since == null ? Duration.zero : DateTime.now().difference(_since!));

  void _playing(bool playing) {
    if (playing && _since == null) {
      _since = DateTime.now();
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    } else if (!playing && _since != null) {
      _banked += DateTime.now().difference(_since!);
      _since = null;
      _timer?.cancel();
      _timer = null;
      setState(() {});
    }
  }

  void _restarted() {
    _banked = Duration.zero;
    _since = ref.read(prompterProvider).playing ? DateTime.now() : null;
    _samples.clear();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    if (ref.read(prompterProvider).playing) _playing(true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Seconds left, or null when it can't be told yet.
  int _secondsLeft(PromptSettings s, PrompterState pr, int words, int index) {
    if (pr.finished) return 0;
    final left = math.max(0, words - 1 - index);
    switch (s.mode) {
      case PromptControlMode.normal:
        final px = ref.watch(scrollRemainingProvider);
        return (px / s.speed).ceil();
      case PromptControlMode.recordedAudio:
        final ctrl = ref.read(prompterProvider.notifier);
        final total = ctrl.audioSeconds;
        if (total != null) return math.max(0, (total - ctrl.audioPosition.inMilliseconds / 1000).ceil());
        return (left / 2.5).ceil();
      case PromptControlMode.voice:
        return (left / _pace()).ceil();
    }
  }

  /// Words per second the reader has really been going, else a typical speaking pace (150 a minute).
  double _pace() {
    const fallback = 150 / 60;
    if (_samples.length < 2) return fallback;
    final (t1, i1) = _samples.last;
    final (t0, i0) = _samples.first;
    if (t1 - t0 < 8 || i1 - i0 < 4) return fallback;
    return (i1 - i0) / (t1 - t0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(prompterProvider.select((p) => p.playing), (_, playing) => _playing(playing));
    ref.listen(prompterProvider.select((p) => p.resetToken), (_, _) => _restarted());
    final s = ref.watch(settingsProvider);
    final pr = ref.watch(prompterProvider);
    final script = ref.watch(studioProvider.select((st) => st.script));
    final ctrl = ref.read(prompterProvider.notifier);
    final words = ctrl.wordCount;
    final percent = readingPercent(ref);
    final index = s.mode == PromptControlMode.normal
        ? ref.watch(readingWordProvider)
        : math.max(pr.progress.confirmedWordIndex, 0);

    final elapsed = _elapsed;
    if (s.mode == PromptControlMode.voice && pr.progress.confirmedWordIndex >= 0) {
      final t = elapsed.inMilliseconds / 1000;
      if (_samples.isEmpty || _samples.last.$2 != index) _samples.add((t, index));
      _samples.removeWhere((e) => t - e.$1 > 30);
    }
    final left = _secondsLeft(s, pr, words, index);
    // Rounded to 5 seconds so the number doesn't flicker.
    final shownLeft = pr.finished ? 0 : (left / 5).round() * 5;

    var section = '';
    if (s.showSections) {
      final markers = sectionMarkers(script);
      final at = sectionIndexForWord(markers, index);
      if (at >= 0) {
        final name = markers[at].name;
        section = '${name.length > 18 ? '${name.substring(0, 17)}…' : name} · ${at + 1} of ${markers.length}  ·  ';
      }
    }
    return Text(
      '$section$percent%  ·  ${_clock(elapsed.inSeconds)} elapsed  ·  ${pr.finished ? '' : '~'}${_clock(shownLeft)} left',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (widget.style ?? const TextStyle()).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}
