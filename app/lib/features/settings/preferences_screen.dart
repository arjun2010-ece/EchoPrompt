
import '../../services/platform.dart';
import 'package:echoprompter_window/echoprompter_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kDebugMode;

import '../../core/entitlements/entitlements.dart';
import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../core/shortcuts/shortcut_binding.dart';
import '../../main.dart' show crashReportingKey;
import '../../services/external_links.dart';
import '../../services/providers.dart';
import '../pro/paywall_dialog.dart';
import '../pro/pro_state.dart';

/// Opens Settings (⌘, on macOS, Ctrl+, on Windows).
Future<void> showPreferences(BuildContext context, {SettingsTab tab = SettingsTab.general}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
      child: PreferencesPane(initialTab: tab),
    ),
  ),
);

enum SettingsTab {
  general('General', Icons.tune),
  shortcuts('Shortcuts', Icons.keyboard_outlined),
  pro('Pro', Icons.star_outline_rounded),
  help('Help', Icons.help_outline);

  const SettingsTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Everything that isn't chosen per session, in tabs: General (appearance, the
/// mirror for glass rigs, screen sharing, crash reports), Shortcuts and Help.
class PreferencesPane extends ConsumerStatefulWidget {
  const PreferencesPane({super.key, this.initialTab = SettingsTab.general});
  final SettingsTab initialTab;

  @override
  ConsumerState<PreferencesPane> createState() => _PreferencesPaneState();
}

class _PreferencesPaneState extends ConsumerState<PreferencesPane> {
  late SettingsTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
          child: Row(children: [
            Text('Settings', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).maybePop()),
          ]),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final t in SettingsTab.values) ...[
              _TabButton(tab: t, selected: t == _tab, onTap: () => setState(() => _tab = t)),
              if (t != SettingsTab.values.last) const SizedBox(width: 4),
            ],
          ]),
        ),
        Flexible(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            shrinkWrap: true,
            children: switch (_tab) {
              SettingsTab.general => const [_GeneralTab()],
              SettingsTab.shortcuts => const [_ShortcutsTab()],
              SettingsTab.pro => const [_ProTab()],
              SettingsTab.help => const [_HelpTab()],
            },
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.tab, required this.selected, required this.onTap});
  final SettingsTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 76,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: selected ? scheme.onSurface.withValues(alpha: 0.1) : null,
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(tab.icon, size: 22, color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(height: 3),
            Text(tab.label, style: TextStyle(fontSize: 11, color: selected ? scheme.onSurface : scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

/// A titled group of rows on a rounded card, as in macOS System Settings.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1, color: scheme.onSurfaceVariant),
          ),
        ),
        // A Material, not a coloured box, so the switch rows inside can paint their own hover and ink.
        Material(
          color: scheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
              children[i],
            ],
          ]),
        ),
      ]),
    );
  }
}

/// A switch row with a short explanation underneath.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.title, required this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: Text(title),
    subtitle: Text(
      subtitle,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    value: value,
    onChanged: onChanged,
  );
}

class _GeneralTab extends ConsumerWidget {
  const _GeneralTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    final prefs = ref.read(prefsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Group(title: 'App', children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            const Expanded(child: Text('Appearance')),
            SegmentedButton<StudioAppearance>(
              showSelectedIcon: false,
              segments: [for (final a in StudioAppearance.values) ButtonSegment(value: a, label: Text(a.label))],
              selected: {s.studioAppearance},
              onSelectionChanged: (v) => set((c) => c.copyWith(studioAppearance: v.first)),
            ),
          ]),
        ),
      ]),
      _Group(title: 'Prompter', children: [
        _SwitchRow(
          title: 'Mirror text',
          subtitle: 'Flips the text left to right, for teleprompter glass (beam-splitter) rigs. Leave off when reading directly from the screen.',
          value: s.mirror,
          onChanged: (v) => set((c) => c.copyWith(mirror: v)),
        ),
        _SwitchRow(
          title: 'Show prompter in screen sharing & recordings',
          subtitle: 'Off by default: the prompter is hidden from most screen-sharing and recording apps. Turn this on only if you want it in your video, '
              'for example when recording a tutorial. Do a 10-second test recording before going live.',
          value: !s.hideFromCapture,
          onChanged: (v) => set((c) => c.copyWith(hideFromCapture: !v)),
        ),
      ]),
      const _CaptureSupportNote(),
      _Group(title: 'Diagnostics', children: [_CrashReportsSwitch(prefs: prefs)]),
    ]);
  }
}

class _ShortcutsTab extends ConsumerWidget {
  const _ShortcutsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text('These work while the prompter is open, even when another app is in front.', style: muted),
      ),
      _Group(title: 'Prompter', children: [for (final a in ShortcutAction.values) _ShortcutRow(action: a)]),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(onPressed: ref.read(shortcutsProvider.notifier).reset, child: const Text('Reset to Defaults')),
      ),
    ]);
  }
}

/// Plan and purchases. The buttons say so while purchases aren't connected (plan Phase 3).
class _ProTab extends ConsumerWidget {
  const _ProTab();

  void _unavailable(BuildContext context, String what) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('$what isn\'t available in this build yet.')));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pro = ref.watch(proProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final used = pro.used.clamp(0, freeScriptLimit);
    final planLabel = switch (pro.plan) {
      ProPlan.free => 'EchoPrompter Free',
      ProPlan.monthly => 'EchoPrompter Pro · Monthly',
      ProPlan.yearly => 'EchoPrompter Pro · Yearly',
      ProPlan.lifetime => 'EchoPrompter Pro · Lifetime',
    };
    Widget row(IconData icon, String title, String sub, Widget action) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Icon(icon, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title), Text(sub, style: muted)])),
        const SizedBox(width: 8),
        action,
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: proAccent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.star_rounded, color: proAccent, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(planLabel, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (!pro.isPro) ...[
                Row(children: [
                  SizedBox(
                    width: 160,
                    child: LinearProgressIndicator(
                      value: used / freeScriptLimit,
                      minHeight: 6,
                      color: proAccent,
                      backgroundColor: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('$used of $freeScriptLimit free scripts used', style: muted),
                ]),
                const SizedBox(height: 6),
                Text('Present up to $freeScriptLimit different scripts, as often as you like. Writing, editing and exporting are always free.', style: muted),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => showPaywall(context),
                  style: FilledButton.styleFrom(backgroundColor: proAccent, foregroundColor: const Color(0xFF1A1A1A)),
                  child: const Text('Upgrade to Pro…', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ] else ...[
                Text(
                  pro.plan == ProPlan.lifetime ? 'Yours for good. Present as many scripts as you like.' : 'Present as many scripts as you like.',
                  style: muted,
                ),
                if (pro.plan != ProPlan.lifetime) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: () => _unavailable(context, 'Managing your subscription'), child: const Text('Manage Subscription…')),
                ],
              ],
            ]),
          ),
        ]),
      ),
      _Group(title: 'Account', children: [
        row(Icons.person_outline, 'Use Pro on all your devices', 'Sign in to use one Pro purchase on up to 5 devices.',
            OutlinedButton(onPressed: () => _unavailable(context, 'Signing in'), child: const Text('Sign In…'))),
        row(Icons.restore, pro.isPro ? 'Purchase not showing?' : 'Already bought Pro?', 'Restore it from your store.',
            OutlinedButton(onPressed: () => _unavailable(context, 'Restoring purchases'), child: const Text('Restore Purchases'))),
      ]),
      // Debug builds only: lets the Pro screens be checked in each state before purchases exist.
      if (kDebugMode)
        _Group(title: 'Preview (debug builds only)', children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<ProPlan>(
              showSelectedIcon: false,
              segments: [for (final p in ProPlan.values) ButtonSegment(value: p, label: Text(p.name))],
              selected: {pro.plan},
              onSelectionChanged: (v) => ref.read(proProvider.notifier).previewPlan(v.first),
            ),
          ),
        ]),
    ]);
  }
}

/// Feedback address and website. Opening mail uses the system opener; with no mail app set up the
/// address can still be copied.
class _HelpTab extends StatelessWidget {
  const _HelpTab();

  Future<void> _email(BuildContext context) async {
    final ok = await openExternal(feedbackMailto());
    if (!ok && context.mounted) {
      await Clipboard.setData(const ClipboardData(text: supportEmail));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No mail app opened. The address is copied: $supportEmail')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget row(IconData icon, String title, String sub, List<Widget> actions) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Icon(icon, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title), Text(sub, style: muted)]),
        ),
        for (final a in actions) ...[const SizedBox(width: 8), a],
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Group(title: 'Feedback', children: [
        row(Icons.mail_outline, 'Email us', supportEmail, [
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: supportEmail));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email address copied')));
              }
            },
          ),
          FilledButton(onPressed: () => _email(context), child: const Text('Email Us…')),
        ]),
      ]),
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 18),
        child: Text(
          'Questions, bugs and ideas are all welcome. The email includes your macOS version, never your scripts or notes.',
          style: muted,
        ),
      ),
      _Group(title: 'Resources', children: [
        row(Icons.language, 'Website & FAQ', 'echoprompter.app', [
          OutlinedButton(onPressed: () => openExternal(Uri.parse(websiteUrl)), child: const Text('Open')),
        ]),
      ]),
    ]);
  }
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
