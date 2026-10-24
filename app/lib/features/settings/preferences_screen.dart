
import '../../services/platform.dart';
import 'package:echoprompter_window/echoprompter_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../core/shortcuts/shortcut_binding.dart';
import '../../main.dart' show crashReportingKey;
import '../../services/providers.dart';

/// Opens Preferences (⌘, on macOS, Ctrl+, on Windows).
Future<void> showPreferences(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
      child: const PreferencesPane(),
    ),
  ),
);

/// Everything that isn't chosen per session: appearance, privacy, the mirror
/// for glass rigs, and global shortcuts.
class PreferencesPane extends ConsumerWidget {
  const PreferencesPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    final prefs = ref.read(prefsProvider);
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
          child: Row(children: [
            Text('Preferences', style: text.titleLarge),
            const Spacer(),
            IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).maybePop()),
          ]),
        ),
        Flexible(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            shrinkWrap: true,
            children: [
              const _Heading('General'),
              Row(children: [
                const Expanded(child: Text('App appearance')),
                SegmentedButton<StudioAppearance>(
                  showSelectedIcon: false,
                  segments: [for (final a in StudioAppearance.values) ButtonSegment(value: a, label: Text(a.label))],
                  selected: {s.studioAppearance},
                  onSelectionChanged: (v) => set((c) => c.copyWith(studioAppearance: v.first)),
                ),
              ]),
              const _Heading('Privacy'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show prompter in screen sharing & recordings'),
                subtitle: Text(
                  'Off by default: the prompter is hidden from most screen-sharing and '
                  'recording apps. Turn this on only if you want the prompter in your video, '
                  'for example when recording a tutorial. Do a 10-second test recording before going live.',
                  style: muted,
                ),
                value: !s.hideFromCapture,
                onChanged: (v) => set((c) => c.copyWith(hideFromCapture: !v)),
              ),
              const _CaptureSupportNote(),
              _CrashReportsSwitch(prefs: prefs),
              const _Heading('Teleprompter rig'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mirror text'),
                subtitle: Text(
                  'Flips the text left to right, for teleprompter glass (beam-splitter) rigs. '
                  'Leave off when reading directly from the screen.',
                  style: muted,
                ),
                value: s.mirror,
                onChanged: (v) => set((c) => c.copyWith(mirror: v)),
              ),
              _Heading('Shortcuts', trailing: TextButton(onPressed: ref.read(shortcutsProvider.notifier).reset, child: const Text('Reset to defaults'))),
              Text(
                'These work while the prompter is open, even when another app is in front.',
                style: muted,
              ),
              const SizedBox(height: 6),
              for (final a in ShortcutAction.values) _ShortcutRow(action: a),
            ],
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 6),
    child: Row(children: [
      Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          letterSpacing: 1,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const Spacer(),
      ?trailing,
    ]),
  );
}

/// Windows builds older than 10 version 2004 cannot hide the window.
class _CaptureSupportNote extends StatefulWidget {
  const _CaptureSupportNote();

  @override
  State<_CaptureSupportNote> createState() => _CaptureSupportNoteState();
}

class _CaptureSupportNoteState extends State<_CaptureSupportNote> {
  bool _supported = true;

  @override
  void initState() {
    super.initState();
    EchoPrompterWindow.supportsCaptureHiding.then(
      (v) => mounted ? setState(() => _supported = v) : null,
      onError: (_) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_supported) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 18, color: Colors.orange),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'This version of Windows can’t hide the prompter from screen sharing. It will be visible to viewers.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}

/// Opt-in crash reporting; applies on next launch. Never sends script content.
class _CrashReportsSwitch extends StatefulWidget {
  const _CrashReportsSwitch({required this.prefs});
  final SharedPreferences prefs;

  @override
  State<_CrashReportsSwitch> createState() => _CrashReportsSwitchState();
}

class _CrashReportsSwitchState extends State<_CrashReportsSwitch> {
  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('Send crash reports'),
    subtitle: Text(
      'Helps fix crashes. Never includes your scripts. Applies the next time EchoPrompter starts.',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    value: widget.prefs.getBool(crashReportingKey) ?? false,
    onChanged: (v) async {
      await widget.prefs.setBool(crashReportingKey, v);
      if (mounted) setState(() {});
    },
  );
}

// --- shortcuts ---------------------------------------------------------------

class _ShortcutRow extends ConsumerWidget {
  const _ShortcutRow({required this.action});
  final ShortcutAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final binding = ref.watch(shortcutsProvider)[action]!;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(action.label)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: scheme.surfaceContainerHigh,
          ),
          child: Text(binding.label(mac: isMacOS), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        ),
        TextButton(
          onPressed: () async {
            final picked = await showDialog<ShortcutBinding>(
              context: context,
              builder: (_) => _ShortcutRecorder(action: action, taken: ref.read(shortcutsProvider)),
            );
            if (picked != null) ref.read(shortcutsProvider.notifier).set(action, picked);
          },
          child: const Text('Change'),
        ),
      ]),
    );
  }
}

/// Captures the next key combination. Esc cancels.
class _ShortcutRecorder extends StatefulWidget {
  const _ShortcutRecorder({required this.action, required this.taken});
  final ShortcutAction action;
  final Map<ShortcutAction, ShortcutBinding> taken;

  @override
  State<_ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<_ShortcutRecorder> {
  String? _problem;

  static String? _keyName(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.space) return 'space';
    if (k == LogicalKeyboardKey.arrowUp) return 'up';
    if (k == LogicalKeyboardKey.arrowDown) return 'down';
    if (k == LogicalKeyboardKey.arrowLeft) return 'left';
    if (k == LogicalKeyboardKey.arrowRight) return 'right';
    final label = k.keyLabel.toLowerCase();
    return supportedShortcutKeys.contains(label) && label.length == 1 ? label : null;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.handled;
    final hw = HardwareKeyboard.instance;
    final mods = {
      if (hw.isControlPressed) ShortcutMod.ctrl,
      if (hw.isAltPressed) ShortcutMod.alt,
      if (hw.isShiftPressed) ShortcutMod.shift,
      if (hw.isMetaPressed) ShortcutMod.meta,
    };
    if (e.logicalKey == LogicalKeyboardKey.escape && mods.isEmpty) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final key = _keyName(e.logicalKey);
    if (key == null) return KeyEventResult.handled; // a modifier on its own, or an unsupported key
    final binding = ShortcutBinding(key, mods);
    if (mods.isEmpty) {
      setState(() => _problem = 'Add Ctrl, Alt, Shift or ${isMacOS ? '⌘' : 'Win'} so it doesn’t get in the way of typing.');
      return KeyEventResult.handled;
    }
    final clash = widget.taken.entries.where((t) => t.key != widget.action && t.value == binding).firstOrNull;
    if (clash != null) {
      setState(() => _problem = 'Already used for “${clash.key.label}”.');
      return KeyEventResult.handled;
    }
    Navigator.of(context).pop(binding);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: _onKey,
    child: AlertDialog(
      title: Text(widget.action.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Press the new shortcut…'),
          if (_problem != null) ...[
            const SizedBox(height: 10),
            Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    ),
  );
}
