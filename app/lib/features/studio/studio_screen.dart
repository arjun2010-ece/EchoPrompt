import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/reading_time.dart';
import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/providers.dart';
import '../../services/storage/script_io.dart';
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
                menuItems: () => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
                onMenu: (s, _) => confirmDeleteScripts(context, ref, [s]),
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
      body: const _Editor(),
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

  void _edit() => setState(() => _editing = true);

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(studioProvider.select((s) => s.history));
    // Rebuild when a script is loaded so the selection follows it.
    ref.watch(studioProvider.select((s) => s.scriptRevision));
    final notifier = ref.read(studioProvider.notifier);

    void newScript() {
      notifier.newScript();
      _edit();
    }

    Future<void> import() async {
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
                    onOpen: (s) {
                      notifier.load(s);
                      _edit();
                    },
                    onOpenDemo: () {
                      notifier.loadDemo();
                      _edit();
                    },
                    onRead: (s) {
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
                    const Expanded(child: _Editor()),
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
class _Editor extends ConsumerStatefulWidget {
  const _Editor();
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final _controller = TextEditingController(text: ref.read(studioProvider).script);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A script replaced from outside the editor (open, new, import) reloads the text.
    ref.listen(studioProvider.select((s) => s.scriptRevision), (_, _) {
      _controller.text = ref.read(studioProvider).script;
    });
    // A script edited from a prompter screen comes back without a revision bump.
    ref.listen(studioProvider.select((s) => s.script), (_, script) {
      if (_controller.text != script) _controller.text = script;
    });
    final script = ref.watch(studioProvider.select((s) => s.script));
    final notifier = ref.read(studioProvider.notifier);
    final theme = Theme.of(context);
    final empty = script.trim().isEmpty;
    final mode = ref.watch(settingsProvider.select((s) => s.mode));
    final audio = ref.watch(audioPathProvider);
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Column(children: [
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _editorMaxWidth),
            child: TextField(
              controller: _controller,
              autofocus: script.isEmpty,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyLarge?.copyWith(fontSize: 19, height: 1.5),
              onChanged: notifier.setScript,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Write or paste your script…',
                contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ),
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
                  final stats = Text(_stats(script), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
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
                  final recordBlocked = empty || (mode == PromptControlMode.recordedAudio && audio == null);
                  final actions = [
                    if (mode != PromptControlMode.normal)
                      _BarButton(
                        icon: Icons.visibility_outlined,
                        label: 'Preview',
                        onPressed: empty ? null : () => _present(context, ref, record: false),
                      ),
                    if (mode == PromptControlMode.normal)
                      _BarButton(
                        icon: Icons.play_arrow_rounded,
                        label: 'Read',
                        primary: true,
                        onPressed: empty ? null : () => _present(context, ref, record: false),
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
    ]);
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
