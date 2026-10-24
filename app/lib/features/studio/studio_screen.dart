import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/clean_script.dart';
import '../../core/script/reading_time.dart';
import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/platform.dart';
import '../../services/providers.dart';
import '../../services/storage/script_io.dart';
import '../../ui/discard_changes_dialog.dart';
import '../read/read_screen.dart';
import '../read/reading_settings.dart';
import '../video/record_screen.dart';
import 'script_list.dart';

/// Window width from which scripts and the editor sit side by side.
const _splitMinWidth = 720.0;
const _listPaneWidth = 340.0;
const _editorMaxWidth = 760.0;

/// Mobile Studio. In a narrow window it is a script library that opens an
/// editor, so each screen has one job and the text gets the whole screen. In a
/// wide window (iPad, landscape, resized windows) the library and the editor
/// share the screen. The layout follows the window, never the device type.
class StudioScreen extends ConsumerWidget {
  const StudioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= _splitMinWidth ? const _SplitStudio() : const _LibraryPage(),
    );
  }
}

// --- Actions shared by both layouts -----------------------------------------

/// Imports a script into the editor; true if one was loaded.
Future<bool> _importScript(WidgetRef ref) async {
  final text = await ScriptIO.importText(ref.read(prefsProvider), ref.read(libraryProvider).directory);
  if (text == null) return false;
  await ref.read(studioProvider.notifier).importScript(text);
  return true;
}

void _exportScript(WidgetRef ref) {
  final body = ref.read(studioProvider).script;
  ScriptIO.exportText(
    body.split('\n').first,
    body,
    prefs: ref.read(prefsProvider),
    scriptsDir: ref.read(libraryProvider).directory,
  );
}

Future<void> _present(BuildContext context, WidgetRef ref, {required bool record}) async {
  final studio = ref.read(studioProvider.notifier);
  await studio.start();
  if (!context.mounted) return;
  // The reader can hand over to recording once the mode was switched to Voice or Audio there.
  var toRecord = record;
  if (!record) {
    toRecord = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
          builder: (_) => const ReadScreen(),
          fullscreenDialog: true,
        )) ??
        false;
    if (toRecord) {
      await studio.start();
      if (!context.mounted) return;
    }
  }
  if (toRecord && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RecordScreen(), fullscreenDialog: true));
  }
  studio.stopPresenting();
}

/// What the primary button will do in each mode.
String _modePlan(PromptControlMode mode) => switch (mode) {
  PromptControlMode.normal => 'Scrolls at your speed. No camera or microphone: use any recorder you like.',
  PromptControlMode.voice => 'Records video and your voice while the prompter follows you.',
  PromptControlMode.recordedAudio => 'Records video while your audio file plays and the prompter follows it.',
};

String _stats(String body) {
  final words = wordCount(body);
  if (words == 0) return 'Empty script';
  final time = readingTimeLabel(words);
  return '$words ${words == 1 ? 'word' : 'words'} · $time';
}

// --- Narrow layout: library, then editor ---------------------------------------------

class _LibraryPage extends ConsumerWidget {
  const _LibraryPage();

  void _openEditor(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _EditorPage()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(studioProvider.select((s) => s.history));
    final notifier = ref.read(studioProvider.notifier);
    final selecting = ref.watch(scriptSelectionProvider) != null;

    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar.large(
          leadingWidth: 196,
          leading: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                'EchoPrompter',
                maxLines: 1,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: 26,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          title: const Text('Scripts'),
          actions: [
            IconButton(
              tooltip: 'Import script',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: () async {
                if (await _importScript(ref) && context.mounted) _openEditor(context);
              },
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.tune),
              onPressed: () => showReadingSettings(context, app: true),
            ),
            const SizedBox(width: 4),
          ],
        ),
        if (history.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyLibrary(
              onNew: () {
                notifier.newScript();
                _openEditor(context);
              },
              onImport: () async {
                if (await _importScript(ref) && context.mounted) _openEditor(context);
              },
              onSample: () => _openEditor(context),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 96 + MediaQuery.viewPaddingOf(context).bottom),
            sliver: SliverToBoxAdapter(
              child: ScriptListBody(
                history: history,
                highlightCurrent: false,
                onOpen: (s) {
                  notifier.load(s);
                  _openEditor(context);
                },
                onOpenDemo: () {
                  notifier.loadDemo();
                  _openEditor(context);
                },
                onRead: (s) {
                  notifier.load(s);
                  _openEditor(context);
                },
                menuItems: () => [
                  const PopupMenuItem(value: 'edit', child: _MenuLabel(Icons.edit_outlined, 'Edit')),
                  PopupMenuItem(
                    value: 'delete',
                    child: _MenuLabel(Icons.delete_outline, 'Delete', color: Theme.of(context).colorScheme.error),
                  ),
                ],
                onMenu: (s, action) {
                  switch (action) {
                    case 'edit':
                      notifier.load(s);
                      _openEditor(context);
                    case 'delete':
                      confirmDeleteScripts(context, ref, [s]);
                  }
                },
              ),
            ),
          ),
      ]),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: ScriptSelectionBar(history: history),
      floatingActionButton: history.isEmpty || selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () {
                notifier.newScript();
                _openEditor(context);
              },
              icon: const Icon(Icons.add),
              label: const Text('New script'),
            ),
    );
  }
}

/// An icon and a label, so the row menu's entries read at a glance.
class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 20, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant),
      const SizedBox(width: 12),
      Text(label, style: color == null ? null : TextStyle(color: color)),
    ]);
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.onNew,
    required this.onImport,
    required this.onSample,
    this.title = 'Your scripts live here',
    this.message = 'Write or paste a script, then press Read to see it scroll.',
    this.showSample = true,
  });

  final String title;
  final String message;
  final bool showSample;

  final VoidCallback onNew;
  final VoidCallback onImport;
  final VoidCallback onSample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.subject_rounded, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: onNew, icon: const Icon(Icons.add), label: const Text('New script'))),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: onImport, icon: const Icon(Icons.file_open_outlined), label: const Text('Import a file'))),
            const SizedBox(height: 4),
            if (showSample) TextButton(onPressed: onSample, child: const Text('Try the sample script')),
          ]),
        ),
      ),
    );
  }
}

class _EditorPage extends ConsumerWidget {
  const _EditorPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(tooltip: 'Export script', icon: const Icon(Icons.ios_share), onPressed: () => _exportScript(ref)),
        IconButton(tooltip: 'Settings', icon: const Icon(Icons.tune), onPressed: () => showReadingSettings(context, app: true)),
        const SizedBox(width: 4),
      ]),
      body: const _Editor(popOnDiscard: true),
    );
  }
}

// --- Wide layout: library and editor together --------------------------------------

class _SplitStudio extends ConsumerStatefulWidget {
  const _SplitStudio();
  @override
  ConsumerState<_SplitStudio> createState() => _SplitStudioState();
}

class _SplitStudioState extends ConsumerState<_SplitStudio> {
  /// The editor opens only once a script is chosen or created, so the right
  /// pane never shows a blank text box next to a "New script" button.
  bool _editing = false;

  /// Android: whether the editor holds unsaved edits.
  final _draftDirty = ValueNotifier(false);

  @override
  void dispose() {
    _draftDirty.dispose();
    super.dispose();
  }

  void _edit() => setState(() => _editing = true);

  /// True when nothing unsaved would be lost, or the user agreed to lose it.
  Future<bool> _canReplaceDraft() async => !_draftDirty.value || await confirmDiscardChanges(context);

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(studioProvider.select((s) => s.history));
    // Rebuild when a script is loaded so the selection follows it.
    ref.watch(studioProvider.select((s) => s.scriptRevision));
    final notifier = ref.read(studioProvider.notifier);

    Future<void> newScript() async {
      if (!await _canReplaceDraft()) return;
      notifier.newScript();
      _edit();
    }

    Future<void> import() async {
      if (!await _canReplaceDraft()) return;
      if (await _importScript(ref)) _edit();
    }

    return Scaffold(
      body: SafeArea(
        child: Row(children: [
          SizedBox(
            width: _listPaneWidth,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(children: [
                  Expanded(child: Text('Scripts', style: Theme.of(context).textTheme.headlineSmall)),
                  IconButton(tooltip: 'Import script', icon: const Icon(Icons.file_open_outlined), onPressed: import),
                  IconButton(tooltip: 'Settings', icon: const Icon(Icons.tune), onPressed: () => showReadingSettings(context, app: true)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(onPressed: newScript, icon: const Icon(Icons.add), label: const Text('New script')),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  child: ScriptListBody(
                    history: history,
                    highlightCurrent: _editing,
                    onOpen: (s) async {
                      if (!await _canReplaceDraft()) return;
                      notifier.load(s);
                      _edit();
                    },
                    onOpenDemo: () async {
                      if (!await _canReplaceDraft()) return;
                      notifier.loadDemo();
                      _edit();
                    },
                    onRead: (s) async {
                      if (!await _canReplaceDraft()) return;
                      notifier.load(s);
                      _edit();
                    },
                    menuItems: () => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
                    onMenu: (s, _) async {
                      final wasOpen = notifier.currentId == s.id;
                      if (await confirmDeleteScripts(context, ref, [s]) && wasOpen) setState(() => _editing = false);
                    },
                  ),
                ),
              ),
              ScriptSelectionBar(
                history: history,
                onDeleted: (currentRemoved) {
                  if (currentRemoved) setState(() => _editing = false);
                },
              ),
            ]),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _editing
                ? Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 12, 0),
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        IconButton(tooltip: 'Export script', icon: const Icon(Icons.ios_share), onPressed: () => _exportScript(ref)),
                      ]),
                    ),
                    Expanded(child: _Editor(dirty: _draftDirty)),
                  ])
                : _EmptyLibrary(
                    onNew: newScript,
                    onImport: import,
                    onSample: _edit,
                    title: history.isEmpty ? 'Your scripts live here' : 'Choose a script',
                    message: history.isEmpty
                        ? 'Write or paste a script, then press Read to see it scroll.'
                        : 'Pick one from the list, or start a new one.',
                    showSample: history.isEmpty,
                  ),
          ),
        ]),
      ),
    );
  }
}

// --- Editor ---------------------------------------------------------------------------

/// The script text plus a bar with its length and the two ways to present it.
///
/// On Android the text is a draft until Save: Save cleans it, stores it and enables Preview and
/// Record; Cancel throws the edits away. Elsewhere typing saves as it goes.
class _Editor extends ConsumerStatefulWidget {
  const _Editor({this.dirty, this.popOnDiscard = false});

  /// Told whether the draft has unsaved edits.
  final ValueNotifier<bool>? dirty;

  /// Leaving with unsaved edits and agreeing to discard them also leaves the screen.
  final bool popOnDiscard;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final _controller = TextEditingController(text: ref.read(studioProvider).script);

  @override
  void dispose() {
    widget.dirty?.value = false;
    _controller.dispose();
    super.dispose();
  }

  bool get _isDirty => isAndroid && _controller.text != ref.read(studioProvider).script;

  void _publishDirty() => widget.dirty?.value = _isDirty;

  void _edited(String text) {
    if (!isAndroid) return ref.read(studioProvider.notifier).setScript(text);
    setState(() {});
    _publishDirty();
  }

  /// Puts the saved script back in the text box.
  void _revert() {
    _controller.text = ref.read(studioProvider).script;
    FocusManager.instance.primaryFocus?.unfocus();
    _publishDirty();
    setState(() {});
  }

  Future<void> _save() async {
    final cleaned = cleanScript(_controller.text);
    if (cleaned.isEmpty) return;
    _controller.value = TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: _controller.selection.baseOffset.clamp(0, cleaned.length)),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    final saved = ref.read(studioProvider.notifier).commitScript(cleaned);
    _publishDirty();
    setState(() {});
    await saved;
  }

  Future<void> _cancel() async {
    if (await confirmDiscardChanges(context)) _revert();
  }

  Future<void> _leave(bool didPop) async {
    if (didPop) return;
    final navigator = Navigator.of(context);
    if (!await confirmDiscardChanges(context)) return;
    _revert();
    if (widget.popOnDiscard) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // A script replaced from outside the editor (open, new, import) reloads the text.
    ref.listen(studioProvider.select((s) => s.scriptRevision), (_, _) {
      _controller.text = ref.read(studioProvider).script;
      _publishDirty();
    });
    // A script edited from a prompter screen comes back without a revision bump.
    ref.listen(studioProvider.select((s) => s.script), (_, script) {
      if (_controller.text != script) _controller.text = script;
      _publishDirty();
    });
    final script = ref.watch(studioProvider.select((s) => s.script));
    final dirty = _isDirty;
    final theme = Theme.of(context);
    final empty = script.trim().isEmpty;
    final mode = ref.watch(settingsProvider.select((s) => s.mode));
    final audio = ref.watch(audioPathProvider);
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) => _leave(didPop),
      child: Column(children: [
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _editorMaxWidth),
            child: Column(children: [
              if (isAndroid)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(onPressed: dirty ? _cancel : null, child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: dirty && cleanScript(_controller.text).isNotEmpty ? _save : null,
                      child: const Text('Save'),
                    ),
                  ]),
                ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: script.isEmpty,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  style: theme.textTheme.bodyLarge?.copyWith(fontSize: 19, height: 1.5),
                  onChanged: _edited,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Write or paste your script…',
                    contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(top: BorderSide(color: theme.dividerTheme.color ?? Colors.transparent)),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _editorMaxWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: LayoutBuilder(builder: (context, c) {
                  // Short, wide windows (a phone in landscape) keep the bar to one
                  // row so the script keeps most of the height.
                  final inline = c.maxWidth >= 520 && MediaQuery.sizeOf(context).height < 600;
                  final stats = Text(_stats(isAndroid ? _controller.text : script), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
                  final modePicker = SegmentedButton<PromptControlMode>(
                    showSelectedIcon: false,
                    segments: [for (final m in PromptControlMode.values) ButtonSegment(value: m, label: Text(m.label))],
                    selected: {mode},
                    onSelectionChanged: (v) => ref.read(settingsProvider.notifier).update((c) => c.copyWith(mode: v.first)),
                  );
                  final audioChip = ActionChip(
                    avatar: const Icon(Icons.audio_file_outlined, size: 18),
                    label: Text(
                      audio == null ? 'Choose audio file' : audio.split(RegExp(r'[\\/]')).last,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () async => ref.read(audioPathProvider.notifier).set(await ScriptIO.chooseAudio() ?? audio),
                  );
                  final recordBlocked = empty || dirty || (mode == PromptControlMode.recordedAudio && audio == null);
                  final actions = [
                    if (mode != PromptControlMode.normal)
                      _BarButton(
                        icon: Icons.visibility_outlined,
                        label: 'Preview',
                        onPressed: empty || dirty ? null : () => _present(context, ref, record: false),
                      ),
                    if (mode == PromptControlMode.normal)
                      _BarButton(
                        icon: Icons.play_arrow_rounded,
                        label: 'Read',
                        primary: true,
                        onPressed: empty || dirty ? null : () => _present(context, ref, record: false),
                      )
                    else
                      _BarButton(
                        icon: Icons.videocam,
                        label: 'Record',
                        primary: true,
                        onPressed: recordBlocked ? null : () => _present(context, ref, record: true),
                      ),
                  ];

                  if (inline) {
                    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Expanded(
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340), child: modePicker),
                          const SizedBox(height: 6),
                          Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            stats,
                            if (mode == PromptControlMode.recordedAudio && !keyboardUp) audioChip,
                          ]),
                        ]),
                      ),
                      const SizedBox(width: 16),
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        actions[i],
                      ],
                    ]);
                  }
                  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    stats,
                    // The keyboard needs the room; the mode can be changed once it is down.
                    if (!keyboardUp) ...[
                      const SizedBox(height: 10),
                      modePicker,
                      const SizedBox(height: 6),
                      Text(_modePlan(mode), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      if (mode == PromptControlMode.recordedAudio) ...[
                        const SizedBox(height: 6),
                        Align(alignment: Alignment.centerLeft, child: audioChip),
                      ],
                    ],
                    const SizedBox(height: 10),
                    Row(children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        Expanded(child: actions[i]),
                      ],
                    ]),
                  ]);
                }),
              ),
            ),
          ),
        ),
      ),
    ]),
    );
  }
}

/// A bar button that keeps its label on one line.
class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.label, required this.onPressed, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis);
    const pad = EdgeInsets.symmetric(horizontal: 18);
    const min = Size(128, 52);
    return primary
        ? FilledButton.icon(
            onPressed: onPressed,
            style: FilledButton.styleFrom(padding: pad, minimumSize: min),
            icon: Icon(icon),
            label: text,
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(padding: pad, minimumSize: min),
            icon: Icon(icon),
            label: text,
          );
  }
}
