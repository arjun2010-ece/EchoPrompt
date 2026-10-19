import '../../services/platform.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/reading_time.dart';
import '../../core/script/saved_script.dart';
import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/providers.dart';
import '../../services/storage/script_io.dart';
import '../../ui/position_picker.dart';
import '../../ui/prompt_text_controls.dart';
import '../settings/preferences_screen.dart';
import 'prompt_preview.dart';

const _positionTipKey = 'EchoPrompt.positionTip.dismissed.v1';

/// Script Studio on macOS and Windows: scripts on the left, the editor in the
/// middle, and on the right a live preview with the few choices that matter
/// before starting (how it follows you, where it sits, how the text looks).
/// Everything else lives in Preferences.
class DesktopStudioScreen extends ConsumerStatefulWidget {
  const DesktopStudioScreen({super.key});

  @override
  ConsumerState<DesktopStudioScreen> createState() =>
      _DesktopStudioScreenState();
}

class _DesktopStudioScreenState extends ConsumerState<DesktopStudioScreen> {
  late final TextEditingController _controller;
  final _focus = FocusNode();
  final _caretWord = ValueNotifier<int>(0);
  final _scaffold = GlobalKey<ScaffoldState>();

  bool get _mac => isMacOS;

  @override
  void initState() {
    super.initState();
    final studio = ref.read(studioProvider);
    _controller = TextEditingController(text: studio.script)
      ..selection = const TextSelection.collapsed(offset: 0)
      ..addListener(_onCaretMoved);
    // Coming back from the prompter: put the caret where the presenter stopped.
    final resume = studio.resumeWordIndex;
    if (resume != null) {
      final offset = offsetOfWord(
        studio.script,
        resume,
      ).clamp(0, studio.script.length);
      _controller.selection = TextSelection.collapsed(offset: offset);
      _caretWord.value = resume;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _caretWord.dispose();
    super.dispose();
  }

  void _onCaretMoved() {
    final sel = _controller.selection;
    _caretWord.value = wordIndexAtOffset(
      _controller.text,
      sel.isValid ? sel.baseOffset : 0,
    );
  }

  Future<void> _import() async {
    final text = await ScriptIO.importText();
    if (text != null) {
      await ref.read(studioProvider.notifier).importScript(text);
    }
  }

  void _export() {
    final body = ref.read(studioProvider).script;
    ScriptIO.exportText(body.split('\n').first, body);
  }

  void _start() {
    if (ref.read(studioProvider).script.trim().isEmpty) return;
    ref.read(studioProvider.notifier).start();
  }

  void _preferences() => showPreferences(context);

  void _closeDrawer() {
    final s = _scaffold.currentState;
    if (s != null && s.isDrawerOpen) s.closeDrawer();
  }

  @override
  Widget build(BuildContext context) {
    // The script was replaced from outside the editor (load, new, import).
    ref.listen(studioProvider.select((s) => s.scriptRevision), (_, _) {
      final script = ref.read(studioProvider).script;
      _controller.value = TextEditingValue(
        text: script,
        selection: const TextSelection.collapsed(offset: 0),
      );
    });

    final width = MediaQuery.sizeOf(context).width;
    final threeColumns = width >= 1040;
    final stacked = width < 780;
    final history = _ScriptList(onPicked: _closeDrawer, onNew: _closeDrawer);
    final editor = _EditorPane(controller: _controller, focus: _focus);
    final inspector = _Inspector(
      caretWord: _caretWord,
      onStart: _start,
      onPreferences: _preferences,
    );

    final Widget body;
    if (stacked) {
      body = Column(
        children: [
          Expanded(flex: 2, child: editor),
          const Divider(height: 1),
          Expanded(flex: 3, child: inspector),
        ],
      );
    } else {
      body = Row(
        children: [
          if (threeColumns) ...[
            SizedBox(width: 250, child: history),
            const VerticalDivider(width: 1),
          ],
          Expanded(flex: 5, child: editor),
          const VerticalDivider(width: 1),
          SizedBox(width: 400, child: inspector),
        ],
      );
    }

    final mod = _mac ? '⌘' : 'Ctrl+';
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.enter, meta: _mac, control: !_mac):
            _start,
        SingleActivator(LogicalKeyboardKey.comma, meta: _mac, control: !_mac):
            _preferences,
        SingleActivator(LogicalKeyboardKey.keyO, meta: _mac, control: !_mac):
            _import,
        SingleActivator(LogicalKeyboardKey.keyN, meta: _mac, control: !_mac):
            ref.read(studioProvider.notifier).newScript,
      },
      child: Scaffold(
        key: _scaffold,
        appBar: AppBar(
          title: const Text('EchoPrompt'),
          leading: threeColumns
              ? null
              : IconButton(
                  tooltip: 'Saved scripts',
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffold.currentState?.openDrawer(),
                ),
          actions: [
            IconButton(
              tooltip: 'New script (${mod}N)',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: ref.read(studioProvider.notifier).newScript,
            ),
            IconButton(
              tooltip: 'Import script (${mod}O)',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _import,
            ),
            IconButton(
              tooltip: 'Export script',
              icon: const Icon(Icons.ios_share),
              onPressed: _export,
            ),
            IconButton(
              tooltip: 'Show scripts folder',
              icon: const Icon(Icons.folder_open),
              onPressed: () =>
                  ScriptIO.reveal(ref.read(libraryProvider).directory),
            ),
            IconButton(
              tooltip: 'Preferences ($mod,)',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _preferences,
            ),
            const SizedBox(width: 8),
          ],
        ),
        drawer: threeColumns ? null : Drawer(child: SafeArea(child: history)),
        body: body,
      ),
    );
  }
}

// --- scripts ---------------------------------------------------------------

class _ScriptList extends ConsumerWidget {
  const _ScriptList({required this.onPicked, required this.onNew});
  final VoidCallback onPicked;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(studioProvider.select((s) => s.history));
    final notifier = ref.read(studioProvider.notifier);
    final currentId = notifier.currentId;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
          child: Row(
            children: [
              Text(
                'SCRIPTS',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  letterSpacing: 1,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'New script',
                icon: const Icon(Icons.add),
                onPressed: () {
                  notifier.newScript();
                  onNew();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: history.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Scripts you present are saved here automatically.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  children: [
                    for (final s in history)
                      _ScriptTile(
                        script: s,
                        selected: s.id == currentId,
                        onTap: () {
                          notifier.load(s);
                          onPicked();
                        },
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ScriptTile extends ConsumerWidget {
  const _ScriptTile({
    required this.script,
    required this.selected,
    required this.onTap,
  });
  final SavedScript script;
  final bool selected;
  final VoidCallback onTap;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this script?'),
        content: Text(
          '“${script.title}” will be removed from your scripts folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(studioProvider.notifier).delete(script);
  }

  void _act(BuildContext context, WidgetRef ref, String action) {
    switch (action) {
      case 'duplicate':
        ref.read(studioProvider.notifier).duplicate(script);
      case 'reveal':
        ScriptIO.reveal(ref.read(libraryProvider).directory);
      case 'delete':
        _delete(context, ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final revealLabel = isMacOS ? 'Show in Finder' : 'Show in Explorer';
    List<PopupMenuEntry<String>> items() => [
      const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
      PopupMenuItem(value: 'reveal', child: Text(revealLabel)),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'delete', child: Text('Delete…')),
    ];
    return GestureDetector(
      onSecondaryTapUp: (d) async {
        final overlay =
            Overlay.of(context).context.findRenderObject()! as RenderBox;
        final choice = await showMenu<String>(
          context: context,
          position: RelativeRect.fromRect(
            d.globalPosition & const Size(1, 1),
            Offset.zero & overlay.size,
          ),
          items: items(),
        );
        if (choice != null && context.mounted) _act(context, ref, choice);
      },
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.45),
        title: Text(script.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(friendlyDate(script.savedAt)),
        onTap: onTap,
        trailing: PopupMenuButton<String>(
          tooltip: 'Script actions',
          icon: const Icon(Icons.more_horiz, size: 18),
          onSelected: (a) => _act(context, ref, a),
          itemBuilder: (_) => items(),
        ),
      ),
    );
  }
}

// --- editor ----------------------------------------------------------------

class _EditorPane extends ConsumerWidget {
  const _EditorPane({required this.controller, required this.focus});
  final TextEditingController controller;
  final FocusNode focus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final script = ref.watch(studioProvider.select((s) => s.script));
    final words = wordCount(script);
    final scheme = Theme.of(context).colorScheme;
    final time = readingTimeLabel(
      words,
      wordsPerMinute: spokenWordsPerMinute.toDouble(),
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Your script',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  words == 0
                      ? 'Empty'
                      : '$words words${time.isEmpty ? '' : ' · $time'}',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 18, height: 1.45),
              onChanged: ref.read(studioProvider.notifier).setScript,
              decoration: InputDecoration(
                hintText: 'Paste or type your script here…',
                filled: true,
                fillColor: scheme.surfaceContainerLow,
                contentPadding: const EdgeInsets.all(16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- inspector ---------------------------------------------------------------

class _Inspector extends ConsumerWidget {
  const _Inspector({
    required this.caretWord,
    required this.onStart,
    required this.onPreferences,
  });
  final ValueNotifier<int> caretWord;
  final VoidCallback onStart;
  final VoidCallback onPreferences;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.mode));
    final hidden = ref.watch(settingsProvider.select((s) => s.hideFromCapture));
    final empty = ref.watch(
      studioProvider.select((s) => s.script.trim().isEmpty),
    );
    final scheme = Theme.of(context).colorScheme;
    final startKey = isMacOS ? '⌘↩' : 'Ctrl+Enter';

    return LayoutBuilder(
      builder: (context, constraints) {
        // The preview stays pinned above the controls, so you always see the
        // result of the slider you're dragging, even in a short window.
        final previewHeight = (constraints.maxHeight * 0.34).clamp(
          120.0,
          250.0,
        );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: ValueListenableBuilder<int>(
                valueListenable: caretWord,
                builder: (_, word, _) =>
                    PromptPreview(wordIndex: word, height: previewHeight),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                children: [
                  const _SectionTitle('Follow'),
                  SegmentedButton<PromptControlMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final m in PromptControlMode.values)
                        ButtonSegment(value: m, label: Text(m.label)),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .update((c) => c.copyWith(mode: v.first)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mode.explanation,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (mode == PromptControlMode.normal) ...[
                    const SizedBox(height: 8),
                    const ScrollSpeedControl(),
                  ],
                  if (mode == PromptControlMode.recordedAudio) ...[
                    const SizedBox(height: 10),
                    const _AudioChooser(),
                  ],
                  const SizedBox(height: 22),
                  const _SectionTitle('Position'),
                  const PositionPicker(),
                  const _PositionTip(),
                  const SizedBox(height: 22),
                  const _SectionTitle('Text'),
                  const PromptTextControls(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Only worth a line when the prompter will show up in
                  // recordings; hidden is the default and needs no reminder.
                  if (!hidden) ...[
                    InkWell(
                      onTap: onPreferences,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.visibility_outlined,
                              size: 16,
                              color: Colors.orange,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Visible in screen sharing and recordings',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  FilledButton.icon(
                    onPressed: empty ? null : onStart,
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Start  $startKey'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        letterSpacing: 1,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _AudioChooser extends ConsumerWidget {
  const _AudioChooser();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(audioPathProvider);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: scheme.surfaceContainerHigh,
      ),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  path == null
                      ? 'No recording selected'
                      : path.split(RegExp(r'[\\/]')).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  path == null
                      ? 'Pick the recording to follow.'
                      : 'EchoPrompt transcribes it once, then follows along.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () async => ref
                .read(audioPathProvider.notifier)
                .set(await ScriptIO.chooseAudio() ?? path),
            child: Text(path == null ? 'Choose…' : 'Change…'),
          ),
        ],
      ),
    );
  }
}

/// A one-time hint under the position picker; remembered once dismissed.
class _PositionTip extends ConsumerStatefulWidget {
  const _PositionTip();

  @override
  ConsumerState<_PositionTip> createState() => _PositionTipState();
}

class _PositionTipState extends ConsumerState<_PositionTip> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(prefsProvider);
    final placement = ref.watch(settingsProvider.select((s) => s.placement));
    final hasNotch = ref.watch(hasNotchProvider).value ?? false;
    if (prefs.getBool(_positionTipKey) ?? false) return const SizedBox.shrink();
    if (placement == PromptPlacement.notch) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final name = PromptPlacement.notch.label(hasNotch: hasNotch);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: scheme.primaryContainer.withValues(alpha: 0.4),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$name puts your words right under the camera, so you keep eye contact.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () => ref
                .read(settingsProvider.notifier)
                .update((c) => c.copyWith(placement: PromptPlacement.notch)),
            child: const Text('Use it'),
          ),
          IconButton(
            tooltip: 'Dismiss tip',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () async {
              await prefs.setBool(_positionTipKey, true);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}
