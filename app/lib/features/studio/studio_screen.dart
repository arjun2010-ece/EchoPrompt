import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../main.dart' show crashReportingKey;
import '../../services/providers.dart';
import '../../services/storage/script_io.dart';
import '../read/read_screen.dart';
import '../video/record_screen.dart';

class StudioScreen extends ConsumerStatefulWidget {
  const StudioScreen({super.key});
  @override
  ConsumerState<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends ConsumerState<StudioScreen> {
  late final _controller = TextEditingController(text: ref.read(studioProvider).script);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setText(String t) {
    _controller.text = t;
    ref.read(studioProvider.notifier).setScript(t);
  }

  Future<void> _openMobile(bool record) async {
    await ref.read(studioProvider.notifier).start();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => record ? const RecordScreen() : const ReadScreen(),
      fullscreenDialog: true,
    ));
    ref.read(studioProvider.notifier).stopPresenting();
  }

  @override
  Widget build(BuildContext context) {
    final studio = ref.watch(studioProvider);
    final notifier = ref.read(studioProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 800;

    final history = ListView(children: [
      const ListTile(title: Text('Saved scripts')),
      for (final s in studio.history)
        ListTile(
          dense: true,
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${s.savedAt.toLocal()}'.split('.').first),
          onTap: () {
            notifier.load(s);
            _controller.text = s.body;
            if (!wide) Navigator.of(context).maybePop();
          },
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => notifier.delete(s)),
        ),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: const Text('EchoPrompt'),
        actions: [
          IconButton(
            tooltip: 'Import script',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () async {
              final t = await ScriptIO.importText();
              if (t != null) {
                await notifier.importScript(t);
                _setText(t);
              }
            },
          ),
          IconButton(
            tooltip: 'Export script',
            icon: const Icon(Icons.ios_share),
            onPressed: () {
              final body = ref.read(studioProvider).script;
              ScriptIO.exportText(body.split('\n').first, body);
            },
          ),
        ],
      ),
      drawer: wide ? null : Drawer(child: history),
      body: Row(children: [
        if (wide) ...[SizedBox(width: 260, child: history), const VerticalDivider(width: 1)],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: notifier.setScript,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(height: 12),
              const _SettingsPanel(),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton.icon(onPressed: () => _openMobile(false), icon: const Icon(Icons.menu_book_outlined), label: const Text('Read')),
                const SizedBox(width: 12),
                FilledButton.icon(onPressed: () => _openMobile(true), icon: const Icon(Icons.videocam), label: const Text('Record')),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _SettingsPanel extends ConsumerWidget {
  const _SettingsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    final audio = ref.watch(audioPathProvider);

    Widget slider(String label, double v, double min, double max, PromptSettings Function(PromptSettings, double) f) =>
        SizedBox(
          width: 240,
          child: Row(children: [
            SizedBox(width: 74, child: Text(label)),
            Expanded(child: Slider(min: min, max: max, value: v.clamp(min, max).toDouble(), onChanged: (x) => set((c) => f(c, x)))),
          ]),
        );
    Widget toggle(String label, bool v, PromptSettings Function(PromptSettings, bool) f) =>
        Row(mainAxisSize: MainAxisSize.min, children: [Text(label), Switch(value: v, onChanged: (x) => set((c) => f(c, x)))]);
    Widget dropdown<T extends Enum>(String label, List<T> values, String Function(T) name, T v, PromptSettings Function(PromptSettings, T) f) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label '),
          DropdownButton<T>(
            value: v,
            items: [for (final e in values) DropdownMenuItem(value: e, child: Text(name(e)))],
            onChanged: (x) => x == null ? null : set((c) => f(c, x)),
          ),
        ]);

    return Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SegmentedButton<PromptControlMode>(
        segments: const [
          ButtonSegment(value: PromptControlMode.normal, label: Text('Normal')),
          ButtonSegment(value: PromptControlMode.voice, label: Text('Voice')),
          ButtonSegment(value: PromptControlMode.recordedAudio, label: Text('Audio')),
        ],
        selected: {s.mode},
        onSelectionChanged: (v) => set((c) => c.copyWith(mode: v.first)),
      ),
      if (s.mode == PromptControlMode.recordedAudio)
        OutlinedButton.icon(
          icon: const Icon(Icons.audio_file_outlined),
          label: Text(audio == null ? 'Choose audio file' : audio.split(RegExp(r'[\\/]')).last),
          onPressed: () async => ref.read(audioPathProvider.notifier).set(await ScriptIO.chooseAudio() ?? audio),
        ),
      slider('Font ${s.fontSize.round()}', s.fontSize, PromptLimits.fontSize.min, PromptLimits.fontSize.max, (c, x) => c.copyWith(fontSize: x)),
      slider('Spacing ${s.lineSpacing.toStringAsFixed(2)}×', s.lineSpacing, PromptLimits.lineSpacing.min, PromptLimits.lineSpacing.max, (c, x) => c.copyWith(lineSpacing: x)),
      slider('Speed', s.speed, PromptLimits.speed.min, PromptLimits.speed.max, (c, x) => c.copyWith(speed: x)),
      slider('Opacity', s.opacity, PromptLimits.opacity.min, PromptLimits.opacity.max, (c, x) => c.copyWith(opacity: x)),
      dropdown('App', StudioAppearance.values, (a) => a.label, s.studioAppearance, (c, x) => c.copyWith(studioAppearance: x)),
      toggle('Mirror', s.mirror, (c, x) => c.copyWith(mirror: x)),
      _CrashToggle(),
      toggle('Rotate 180°', s.rotated, (c, x) => c.copyWith(rotated: x)),
    ]);
  }
}

/// Opt-in crash reporting; applies on next launch. Never sends script content.
class _CrashToggle extends ConsumerStatefulWidget {
  @override
  ConsumerState<_CrashToggle> createState() => _CrashToggleState();
}

class _CrashToggleState extends ConsumerState<_CrashToggle> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(prefsProvider);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('Send crash reports'),
      Switch(
        value: prefs.getBool(crashReportingKey) ?? false,
        onChanged: (v) async {
          await prefs.setBool(crashReportingKey, v);
          setState(() {});
        },
      ),
    ]);
  }
}
