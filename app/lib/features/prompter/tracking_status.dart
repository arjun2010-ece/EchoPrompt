import 'package:flutter/material.dart';

import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import 'prompt_surface.dart';
import 'prompter_controller.dart';

/// Whether the prompter is following the reader, shown by the mobile Read and
/// Record overlays.
enum Tracking { scrolling, listening, following, preparing, paused, lost, unavailable, finished }

class TrackingStatus {
  const TrackingStatus(this.tracking, this.label, {this.detail});
  final Tracking tracking;
  final String label;

  /// Explains a problem, or tells the reader how to recover.
  final String? detail;
}

/// Statuses the controller reports that are not problems.
const _benignStatuses = {'', 'Listening', 'Playing', 'Finished', 'Ready — press Play'};

TrackingStatus trackingStatusFor(PromptControlMode mode, PrompterState pr, String? audioPath) {
  if (mode == PromptControlMode.normal) {
    if (pr.finished) return const TrackingStatus(Tracking.finished, 'End of script');
    return pr.playing ? const TrackingStatus(Tracking.scrolling, 'Scrolling') : const TrackingStatus(Tracking.paused, 'Paused');
  }
  if (pr.preparing) return const TrackingStatus(Tracking.preparing, 'Syncing audio…');
  if (!pr.playing && !_benignStatuses.contains(pr.status)) {
    return TrackingStatus(Tracking.unavailable, 'Unavailable', detail: pr.status);
  }
  if (!pr.playing && mode == PromptControlMode.recordedAudio && audioPath == null) {
    return const TrackingStatus(Tracking.unavailable, 'Unavailable', detail: 'Choose an audio file in settings');
  }
  if (pr.finished) return const TrackingStatus(Tracking.finished, 'End of script');
  if (pr.playing && pr.lost) {
    return const TrackingStatus(
      Tracking.lost,
      'Lost your place',
      detail: 'Repeat your last phrase, or tap the word you are on',
    );
  }
  if (pr.playing) {
    return mode == PromptControlMode.voice
        ? const TrackingStatus(Tracking.listening, 'Listening')
        : const TrackingStatus(Tracking.following, 'Following audio');
  }
  return TrackingStatus(Tracking.paused, mode == PromptControlMode.voice ? 'Voice paused' : 'Paused');
}

Color trackingColor(Tracking t) => switch (t) {
  Tracking.listening => const Color(0xFF3DD68C),
  Tracking.scrolling || Tracking.following || Tracking.preparing => const Color(0xFFFFA24A),
  Tracking.lost => const Color(0xFFFFD166),
  Tracking.unavailable => const Color(0xFFFF6B5E),
  Tracking.paused || Tracking.finished => const Color(0xFFB4B0A8),
};

/// A rounded status chip: a dot (breathing while the microphone is live) and
/// a label. [showMode] prefixes the mode name.
class TrackingPill extends StatelessWidget {
  const TrackingPill({super.key, required this.mode, required this.status, this.showMode = true, this.dense = false});

  final PromptControlMode mode;
  final TrackingStatus status;
  final bool showMode;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = trackingColor(status.tracking);
    final label = showMode ? '${mode.label} · ${status.label}' : status.label;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      liveRegion: true,
      label: 'Prompter: ${mode.label} mode, ${status.label}',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 14, vertical: dense ? 5 : 8),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _Dot(color: color, pulse: status.tracking == Tracking.listening && !reduceMotion),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: promptText, fontSize: dense ? 12 : 14, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulse});
  final Color color;
  final bool pulse;
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _anim.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_anim.isAnimating) {
      _anim.repeat(reverse: true);
    } else if (!widget.pulse && _anim.isAnimating) {
      _anim
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, _) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.6 * _anim.value), blurRadius: 8, spreadRadius: 3 * _anim.value)],
      ),
    ),
  );
}
