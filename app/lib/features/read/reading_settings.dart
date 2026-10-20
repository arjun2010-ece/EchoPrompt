import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../main.dart' show crashReportingKey;
import '../../services/providers.dart';
import '../../services/storage/script_io.dart';

/// Width at which settings open as a side panel instead of a bottom sheet.
const _panelMinWidth = 720.0;

/// Opens the reading settings: a bottom sheet on narrow windows, a panel
/// anchored to the trailing edge on wide ones. [app] adds the app-wide
/// choices (appearance, crash reports) that Studio offers but the reader
/// does not.
Future<void> showReadingSettings(BuildContext context, {bool app = false}) {
  final wide = MediaQuery.sizeOf(context).width >= _panelMinWidth;
  if (!wide) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => ReadingSettings(app: app, controller: scroll),
      ),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close settings',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (_, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            color: Theme.of(ctx).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 400, child: ReadingSettings(app: app)),
          ),
        ),
      ),
    ),
  );
}

/// How the prompter follows and shows the script. Frequent choices (mode, text
/// size) sit first; rarely changed ones follow.
class ReadingSettings extends ConsumerWidget {
  const ReadingSettings({super.key, this.app = false, this.controller});

  final bool app;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    final audio = ref.watch(audioPathProvider);
    final text = Theme.of(context).textTheme;

    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 4),
      child: Text(title, style: text.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );

    Widget slider(String label, String value, double v, ({double min, double max}) r, PromptSettings Function(PromptSettings, double) f) =>
        Semantics(
          label: label,
          value: value,
          child: Row(children: [
            Expanded(flex: 3, child: Text(label)),
            Expanded(
              flex: 5,
              child: Slider(min: r.min, max: r.max, value: v.clamp(r.min, r.max).toDouble(), onChanged: (x) => set((c) => f(c, x))),
            ),
            SizedBox(width: 52, child: Text(value, textAlign: TextAlign.end, style: text.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))),
          ]),
        );

    return ListView(
      controller: controller,
      padding: EdgeInsets.fromLTRB(24, controller == null ? 20 : 4, 24, 24 + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        Text('Reading settings', style: text.titleLarge),
        section('Follow'),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<PromptControlMode>(
            showSelectedIcon: false,
            segments: [
              for (final m in PromptControlMode.values) ButtonSegment(value: m, label: Text(m.label)),
            ],
            selected: {s.mode},
            onSelectionChanged: (v) => set((c) => c.copyWith(mode: v.first)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(s.mode.explanation, style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        if (s.mode == PromptControlMode.recordedAudio)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.audio_file_outlined),
              label: Text(audio == null ? 'Choose audio file' : audio.split(RegExp(r'[\\/]')).last, overflow: TextOverflow.ellipsis),
              onPressed: () async => ref.read(audioPathProvider.notifier).set(await ScriptIO.chooseAudio() ?? audio),
            ),
          ),
        section('Text'),
        slider('Size', '${s.fontSize.round()}', s.fontSize, PromptLimits.fontSize, (c, x) => c.copyWith(fontSize: x)),
        slider('Spacing', '${s.lineSpacing.toStringAsFixed(2)}×', s.lineSpacing, PromptLimits.lineSpacing, (c, x) => c.copyWith(lineSpacing: x)),
        if (s.mode == PromptControlMode.normal)
          slider('Speed', '${(s.speed / 24).toStringAsFixed(1)}×', s.speed, PromptLimits.speed, (c, x) => c.copyWith(speed: x)),
        if (app) slider('Overlay opacity', '${(s.opacity * 100).round()}%', s.opacity, PromptLimits.opacity, (c, x) => c.copyWith(opacity: x)),
        section('Teleprompter glass'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mirror text'),
          subtitle: const Text('For a beam-splitter glass rig'),
          value: s.mirror,
          onChanged: (v) => set((c) => c.copyWith(mirror: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Rotate 180°'),
          subtitle: const Text('For a device mounted upside down'),
          value: s.rotated,
          onChanged: (v) => set((c) => c.copyWith(rotated: v)),
        ),
        if (app) ...[
          section('App'),
          Row(children: [
            const Expanded(child: Text('Appearance')),
            SegmentedButton<StudioAppearance>(
              showSelectedIcon: false,
              segments: [for (final a in StudioAppearance.values) ButtonSegment(value: a, label: Text(a.label))],
              selected: {s.studioAppearance},
              onSelectionChanged: (v) => set((c) => c.copyWith(studioAppearance: v.first)),
            ),
          ]),
          const _CrashToggle(),
        ],
      ],
    );
  }
}

/// Opt-in crash reporting; applies on next launch. Never sends script content.
class _CrashToggle extends ConsumerStatefulWidget {
  const _CrashToggle();
  @override
  ConsumerState<_CrashToggle> createState() => _CrashToggleState();
}

class _CrashToggleState extends ConsumerState<_CrashToggle> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(prefsProvider);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Send crash reports'),
      subtitle: const Text('Never includes your scripts. Applies on next launch.'),
      value: prefs.getBool(crashReportingKey) ?? false,
      onChanged: (v) async {
        await prefs.setBool(crashReportingKey, v);
        setState(() {});
      },
    );
  }
}
