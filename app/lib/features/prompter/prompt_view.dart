import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/prompt_settings.dart';
import '../../services/providers.dart';
import 'prompt_surface.dart';
import 'prompter_controller.dart';
import 'tracking_status.dart';

export 'prompt_surface.dart' show PromptLayoutStyle;

/// Mobile prompter: the shared text surface plus a simple control row. Used
/// by the Read screen and as the overlay on the Record screen. (The desktop
/// overlay has its own layouts in `desktop_prompter_screen.dart`.)
class PromptView extends ConsumerWidget {
  const PromptView({
    super.key,
    this.style = PromptLayoutStyle.full,
    this.backgroundOpacity,
    this.showControls = true,
    this.onClose,
    this.trailing = const [],
  });

  final PromptLayoutStyle style;
  final double? backgroundOpacity;

  /// False when the host screen shows [PromptControlBar] itself.
  final bool showControls;
  final VoidCallback? onClose;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final bg = promptBackground.withValues(alpha: backgroundOpacity ?? s.opacity);
    final compact = style != PromptLayoutStyle.full;

    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 12 : 0),
      child: ColoredBox(
        color: bg,
        child: Column(children: [
          Expanded(child: PromptSurface(style: style, onWordTap: true)),
          if (showControls) PromptControlBar(compact: compact, onClose: onClose, trailing: trailing),
        ]),
      ),
    );
  }
}

/// Play/restart/speed/mode controls for the prompter.
class PromptControlBar extends ConsumerWidget {
  const PromptControlBar({super.key, this.compact = true, this.onClose, this.trailing = const [], this.color, this.onSettings});

  final bool compact;

  /// Replaces the mode menu with a settings button, for screens whose mode is fixed.
  final VoidCallback? onSettings;
  final VoidCallback? onClose;
  final List<Widget> trailing;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final pr = ref.watch(prompterProvider);
    final c = ref.read(prompterProvider.notifier);
    final set = ref.read(settingsProvider.notifier).update;
    const fg = promptText;
    return Material(
    color: color ?? Colors.black.withValues(alpha: 0.35),
    child: IconTheme(
      data: IconThemeData(color: fg, size: compact ? 18 : 22),
      child: Row(children: [
        IconButton(
          tooltip: pr.playing ? 'Pause' : 'Play',
          icon: Icon(pr.playing ? Icons.pause : Icons.play_arrow),
          onPressed: pr.preparing ? null : c.togglePlay,
        ),
        IconButton(tooltip: 'Restart', icon: const Icon(Icons.replay), onPressed: c.restart),
        if (s.mode == PromptControlMode.normal) ...[
          IconButton(icon: const Icon(Icons.remove), tooltip: 'Slower', onPressed: () => set((v) => v.copyWith(speed: math.max(6, v.speed - 3)))),
          Text('${(s.speed / 24).toStringAsFixed(2)}×', style: TextStyle(color: fg, fontSize: 12)),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Faster', onPressed: () => set((v) => v.copyWith(speed: math.min(72, v.speed + 3)))),
        ],
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TrackingPill(
              mode: s.mode,
              status: trackingStatusFor(s.mode, pr, ref.watch(audioPathProvider)),
              showMode: false,
              dense: true,
            ),
          ),
        ),
        if (onSettings != null)
          IconButton(tooltip: 'Settings', icon: const Icon(Icons.tune), onPressed: onSettings)
        else
        PopupMenuButton<PromptControlMode>(
          tooltip: 'Mode',
          icon: Icon(Icons.tune, color: fg),
          initialValue: s.mode,
          onSelected: (m) => set((v) => v.copyWith(mode: m)),
          itemBuilder: (_) => const [
            PopupMenuItem(value: PromptControlMode.normal, child: Text('Normal scrolling')),
            PopupMenuItem(value: PromptControlMode.voice, child: Text('Voice control')),
            PopupMenuItem(value: PromptControlMode.recordedAudio, child: Text('Recorded audio')),
          ],
        ),
        ...trailing,
        if (onClose != null) IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: onClose),
      ]),
    ),
  );
  }
}
