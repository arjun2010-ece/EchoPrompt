import '../../services/platform.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/entitlements/entitlements.dart';
import '../../core/script/clean_script.dart';
import '../../core/script/reading_time.dart';
import '../../core/script/saved_script.dart';
import '../../core/script/sections.dart';
import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/providers.dart';
import '../../services/speech/speech_requirements.dart';
import '../../services/storage/script_io.dart';
import '../../ui/discard_changes_dialog.dart';
import '../../ui/position_picker.dart';
import '../../ui/prompt_text_controls.dart';
import '../settings/preferences_screen.dart';
import '../pro/paywall_dialog.dart';
import '../pro/pro_state.dart';
import '../pro/upgrade_card.dart';
import '../menu/studio_commands.dart';
import '../notes/notes_pane.dart';
import '../notes/notes_state.dart';
import 'audio_check.dart';
import 'prompt_preview.dart';
import 'script_list.dart';
import 'script_text_controller.dart';

const _positionTipKey = 'EchoPrompter.positionTip.dismissed.v1';

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
  late final TextEditingController _titleController;
  final _focus = FocusNode();
  final _caretWord = ValueNotifier<int>(0);
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Whether the editor holds edits that are not saved yet.
  final _dirty = ValueNotifier(false);

  bool get _mac => isMacOS;

  bool get _isDirty {
    final studio = ref.read(studioProvider);
    return _controller.text != studio.script ||
        _titleController.text.trim() != studio.title.trim();
  }

  void _publishDirty() => _dirty.value = _isDirty;

  /// True when nothing unsaved would be lost, or the user agreed to lose it.
  Future<bool> _canReplaceDraft() async => !_dirty.value || await confirmDiscardChanges(context);

  /// Puts the saved script back in the text box.
  void _revert() {
    _controller.value = TextEditingValue(
      text: ref.read(studioProvider).script,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _titleController.text = ref.read(studioProvider).title;
    _publishDirty();
  }

  Future<void> _cancel() async {
    if (await confirmDiscardChanges(context)) _revert();
  }

  Future<void> _save() async {
    if (_onNotes) return ref.read(noteEditorSaveProvider)?.call();
    final cleaned = cleanScript(_controller.text);
    if (!_dirty.value || cleaned.isEmpty) return;
    _controller.value = TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: _controller.selection.baseOffset.clamp(0, cleaned.length)),
    );
    final saved = ref
        .read(studioProvider.notifier)
        .commitScript(cleaned, title: _titleController.text.trim());
    _publishDirty();
    await saved;
  }

  Future<void> _newScript() async {
    if (!await _canReplaceDraft()) return;
    ref.read(libraryTabProvider.notifier).show(LibraryTab.scripts);
    ref.read(studioProvider.notifier).newScript();
  }

  bool get _onNotes => ref.read(libraryTabProvider) == LibraryTab.notes;

  Future<void> _newNote() async {
    if (!await canLeaveNoteDraft(context, ref)) return;
    ref.read(libraryTabProvider.notifier).show(LibraryTab.notes);
    ref.read(notesProvider.notifier).startNew();
  }

  @override
  void initState() {
    super.initState();
    final studio = ref.read(studioProvider);
    _controller = ScriptTextController(text: studio.script)
      ..selection = const TextSelection.collapsed(offset: 0)
      ..addListener(_onCaretMoved);
    _titleController = TextEditingController(text: studio.title)
      ..addListener(_publishDirty);
    // The menu bar reaches the Studio through these while it is showing.
    Future.microtask(
      () => _commandSlot.set(
        StudioCommands(
          newScript: _newScript,
          newNote: _newNote,
          importFile: _import,
          exportFile: _export,
          save: _save,
          insertSection: _insertSection,
          start: _start,
          settings: _preferences,
          showScriptsFolder: () => ScriptIO.reveal(ref.read(libraryProvider).directory),
          showNotesFolder: () => ScriptIO.reveal(ref.read(notesLibraryProvider).directory),
          deleteScript: _deleteScript,
          showScripts: () => _showTab(LibraryTab.scripts),
          showNotes: () => _showTab(LibraryTab.notes),
        ),
      ),
    );
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

  /// Deletes the open script, after asking, like the list's Delete.
  Future<void> _deleteScript() async {
    if (_onNotes) return;
    final id = ref.read(studioProvider.notifier).currentId;
    final script = ref.read(studioProvider).history.where((s) => s.id == id).firstOrNull;
    if (script != null) await confirmDeleteScripts(context, ref, [script]);
  }

  Future<void> _showTab(LibraryTab tab) async {
    if (tab == LibraryTab.scripts && !await canLeaveNoteDraft(context, ref)) return;
    ref.read(libraryTabProvider.notifier).show(tab);
  }

  late final StudioCommandsNotifier _commandSlot = ref.read(studioCommandsProvider.notifier);

  @override
  void dispose() {
    Future.microtask(() => _commandSlot.set(null));
    _controller.dispose();
    _titleController.dispose();
    _focus.dispose();
    _caretWord.dispose();
    _dirty.dispose();
    super.dispose();
  }

  void _onCaretMoved() {
    final sel = _controller.selection;
    _caretWord.value = wordIndexAtOffset(
      _controller.text,
      sel.isValid ? sel.baseOffset : 0,
    );
  }

  Future<void> _importNote() async {
    if (!await canLeaveNoteDraft(context, ref)) return;
    final file = await ScriptIO.importTextFile(ref.read(prefsProvider), ref.read(notesLibraryProvider).directory);
    if (file != null) await ref.read(notesProvider.notifier).importNote(file.name, file.text);
  }

  Future<void> _import() async {
    if (_onNotes) return _importNote();
    if (!await _canReplaceDraft()) return;
    final file = await ScriptIO.importTextFile(
      ref.read(prefsProvider),
      ref.read(libraryProvider).directory,
    );
    if (file != null) {
      await ref
          .read(studioProvider.notifier)
          .importScript(file.text, title: titleFromFileName(file.name));
    }
  }

  Future<void> _export() async {
    if (_onNotes) {
      final note = ref.read(notesProvider).current;
      if (note == null) return;
      final path = await ScriptIO.exportText(
        note.title,
        note.body,
        prefs: ref.read(prefsProvider),
        scriptsDir: ref.read(notesLibraryProvider).directory,
      );
      if (path != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported to $path')));
      return;
    }
    final studio = ref.read(studioProvider);
    final body = studio.script;
    final path = await ScriptIO.exportText(
      studio.title.trim().isNotEmpty ? studio.title : body.split('\n').first,
      body,
      prefs: ref.read(prefsProvider),
      scriptsDir: ref.read(libraryProvider).directory,
    );
    if (path == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported to $path')));
  }

  Future<void> _start() async {
    if (_onNotes) return; // notes are never presented
    if (_dirty.value || ref.read(studioProvider).script.trim().isEmpty) return;
    if (ref.read(settingsProvider).mode == PromptControlMode.recordedAudio &&
        audioStartBlocker(ref.read(audioCheckProvider)) != null) {
      return;
    }
    // A 6th new script on the free plan opens the plans straight away: one click to buy.
    final studio = ref.read(studioProvider.notifier);
    if (!ref.read(proProvider).canPresent(studio.currentId)) {
      if (mounted) await showPaywall(context, reason: 'You\'ve used your $freeScriptLimit free scripts.');
      return;
    }
    if (!await _speechSettingReady()) return;
    studio.start();
    // The built-in demo is never saved, so it never counts toward the free scripts.
    final id = studio.currentId;
    if (id != null) ref.read(proProvider.notifier).recordStart(id);
  }

  /// Voice and Audio mode need something only the reader can allow or turn on (speech or microphone access
  /// and Dictation on macOS). Offers the Settings page first; "Start
  /// anyway" goes on regardless, since a setting can't always be read.
  Future<bool> _speechSettingReady() async {
    if (ref.read(settingsProvider).mode == PromptControlMode.normal) return true;
    final need = await unmetSpeechRequirement();
    if (need == null || !mounted) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.mic_none_rounded, size: 32),
        title: Text(need.title),
        content: Text(need.message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop('start'), child: const Text('Start anyway')),
          FilledButton(onPressed: () => Navigator.of(context).pop('settings'), child: const Text('Open settings')),
        ],
      ),
    );
    if (choice == 'settings') await need.openSettings();
    return choice == 'start';
  }

  void _preferences() => showPreferences(context);

  /// Puts a new `[Section N]` line at the caret, on a line of its own, with its name selected to type over.
  void _insertSection() {
    if (_onNotes) return;
    final studio = ref.read(studioProvider);
    if (studio.script == StudioNotifier.welcome && ref.read(studioProvider.notifier).currentId == null) return;
    final text = _controller.text;
    final sel = _controller.selection;
    final at = sel.isValid ? sel.start : text.length;
    final name = 'Section ${sectionMarkers(text).length + 1}';
    final lead = at > 0 && text[at - 1] != '\n' ? '\n' : '';
    final inserted = '$lead[$name]\n';
    final nameStart = at + lead.length + 1;
    _controller.value = TextEditingValue(
      text: text.replaceRange(at, sel.isValid ? sel.end : at, inserted),
      selection: TextSelection(
        baseOffset: nameStart,
        extentOffset: nameStart + name.length,
      ),
    );
    _focus.requestFocus();
    _publishDirty();
  }

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
      _titleController.text = ref.read(studioProvider).title;
      _publishDirty();
    });

    final notes = ref.watch(libraryTabProvider) == LibraryTab.notes;
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final threeColumns = width >= 1090;
    final stacked = width < 780;
    final history = _ScriptList(onPicked: _closeDrawer, onNew: _closeDrawer, canReplace: _canReplaceDraft);
    final editor = _EditorPane(
      controller: _controller,
      titleController: _titleController,
      focus: _focus,
      dirty: _dirty,
      onEdited: _publishDirty,
      onSave: _save,
      onCancel: _cancel,
      onInsertSection: _insertSection,
    );
    final inspector = _Inspector(
      caretWord: _caretWord,
      dirty: _dirty,
      onStart: _start,
      onPreferences: _preferences,
    );

    // Notes are never presented, so while they show there is no inspector (no Follow, Position or Start).
    final Widget body;
    if (notes) {
      body = Row(
        children: [
          if (threeColumns) ...[
            SizedBox(width: 300, child: Material(color: scheme.surfaceContainer, child: history)),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: NotesPane(onImport: _importNote)),
        ],
      );
    } else if (stacked) {
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
            SizedBox(width: 300, child: Material(color: scheme.surfaceContainer, child: history)),
            const VerticalDivider(width: 1),
          ],
          Expanded(flex: 5, child: editor),
          const VerticalDivider(width: 1),
          SizedBox(width: 400, child: Material(color: scheme.surfaceContainerLow, child: inspector)),
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
            _newScript,
        SingleActivator(LogicalKeyboardKey.keyN, meta: _mac, control: !_mac, alt: true):
            _newNote,
        SingleActivator(LogicalKeyboardKey.keyS, meta: _mac, control: !_mac, shift: true):
            _export,
        SingleActivator(LogicalKeyboardKey.keyS, meta: _mac, control: !_mac):
            _save,
        SingleActivator(LogicalKeyboardKey.keyK, meta: _mac, control: !_mac):
            _insertSection,
      },
      child: Scaffold(
        key: _scaffold,
        appBar: AppBar(
          title: const Text('EchoPrompter'),
          // Nothing scrolls under this bar; ignore scroll notifications so the
          // script list relaying out on selection can't flash the header.
          notificationPredicate: (_) => false,
          scrolledUnderElevation: 0,
          leading: threeColumns
              ? null
              : IconButton(
                  tooltip: 'Saved scripts',
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffold.currentState?.openDrawer(),
                ),
          actions: [
            IconButton(
              tooltip: notes ? 'New note (${_mac ? '⌥⌘N' : 'Ctrl+Alt+N'})' : 'New script (${mod}N)',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: notes ? _newNote : _newScript,
            ),
            IconButton(
              tooltip: '${notes ? 'Import note' : 'Import script'} (${mod}O)',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _import,
            ),
            IconButton(
              tooltip: 'Export ${notes ? 'note' : 'script'} (${_mac ? '⇧⌘S' : 'Ctrl+Shift+S'})',
              icon: const Icon(Icons.ios_share),
              onPressed: _export,
            ),
            IconButton(
              tooltip: notes ? 'Show notes folder' : 'Show scripts folder',
              icon: const Icon(Icons.folder_open),
              onPressed: () => ScriptIO.reveal(
                ref.read(notes ? notesLibraryProvider : libraryProvider).directory,
              ),
            ),
            IconButton(
              tooltip: 'Settings ($mod,)',
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
  const _ScriptList({required this.onPicked, required this.onNew, required this.canReplace});
  final VoidCallback onPicked;
  final VoidCallback onNew;

  /// Asks before unsaved edits are replaced by another script.
  final Future<bool> Function() canReplace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(studioProvider.select((s) => s.history));
    // currentId is not part of the state; load/new/duplicate/import change it
    // together with scriptRevision, so watch that to refresh the selection.
    ref.watch(studioProvider.select((s) => s.scriptRevision));
    final notifier = ref.read(studioProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final tab = ref.watch(libraryTabProvider);
    final tabs = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<LibraryTab>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: LibraryTab.scripts, label: Text('Scripts')),
            ButtonSegment(value: LibraryTab.notes, label: Text('Notes')),
          ],
          selected: {tab},
          onSelectionChanged: (v) async {
            if (v.first == LibraryTab.scripts && !await canLeaveNoteDraft(context, ref)) return;
            ref.read(libraryTabProvider.notifier).show(v.first);
          },
        ),
      ),
    );
    if (tab == LibraryTab.notes) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [tabs, const Expanded(child: NoteSidebar()), const UpgradeCard()]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tabs,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
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
                onPressed: () async {
                  if (!await canReplace()) return;
                  notifier.newScript();
                  onNew();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ScriptListBody(
              history: history,
              dense: true,
              showPreview: true,
              onOpen: (s) async {
                if (!await canReplace()) return;
                notifier.load(s);
                onPicked();
              },
              onOpenDemo: () async {
                if (!await canReplace()) return;
                notifier.loadDemo();
                onPicked();
              },
              menuItems: () => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                PopupMenuItem(
                  value: 'reveal',
                  child: Text(isMacOS ? 'Show in Finder' : 'Show in Explorer'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'delete', child: Text('Delete…')),
              ],
              onMenu: (s, action) async {
                switch (action) {
                  case 'edit':
                    if (!await canReplace()) return;
                    notifier.load(s);
                    onPicked();
                  case 'duplicate':
                    if (!await canReplace()) return;
                    notifier.duplicate(s);
                  case 'reveal':
                    ScriptIO.reveal(ref.read(libraryProvider).directory);
                  case 'delete':
                    confirmDeleteScripts(context, ref, [s]);
                }
              },
            ),
          ),
        ),
        // While scripts are being selected the selection bar takes the card's place.
        if (ref.watch(scriptSelectionProvider) == null) const UpgradeCard(),
        ScriptSelectionBar(history: history),
      ],
    );
  }
}

// --- editor ----------------------------------------------------------------

class _EditorPane extends ConsumerWidget {
  const _EditorPane({
    required this.controller,
    required this.titleController,
    required this.focus,
    required this.dirty,
    required this.onEdited,
    required this.onSave,
    required this.onCancel,
    required this.onInsertSection,
  });
  final TextEditingController controller;
  final TextEditingController titleController;
  final FocusNode focus;
  final ValueNotifier<bool> dirty;
  final VoidCallback onEdited;
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final VoidCallback onInsertSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final script = ref.watch(studioProvider.select((s) => s.script));
    // The built-in demo is for looking at: it has no Save and Cancel and can't be edited, so a draft
    // can't get stuck on it. Create a script (New) to write your own.
    ref.watch(studioProvider.select((s) => s.scriptRevision));
    final demo =
        script == StudioNotifier.welcome &&
        ref.read(studioProvider.notifier).currentId == null;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mod = isMacOS ? '⌘' : 'Ctrl+';
    return LayoutBuilder(
      builder: (context, box) {
        // Narrow editors keep Insert Section as an icon, so the word count still has room.
        final compact = box.maxWidth < 600;
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The title names the script in the list and its file. Typing is a draft until Save, like the text.
              if (demo)
                Text(
                  'Welcome to EchoPrompter',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                ListenableBuilder(
                  listenable: titleController,
                  builder: (context, _) {
                    final n = titleController.text.characters.length;
                    return TextField(
                      controller: titleController,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(
                          SavedScript.maxTitleLength,
                        ),
                      ],
                      maxLines: 1,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Title',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        // A counter only when the limit is near, so it doesn't clutter a short title.
                        suffixText: n >= 20
                            ? '$n/${SavedScript.maxTitleLength}'
                            : null,
                        suffixStyle: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 8),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 10),
              // Edits stay a draft until Save; Cancel puts the saved script back.
              Row(
                children: [
                  Expanded(
                    // Counts the text as typed, not only as saved, so Insert Section shows at once.
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) {
                        final text = demo ? script : controller.text;
                        final words = wordCount(text);
                        final time = readingTimeLabel(
                          words,
                          wordsPerMinute: spokenWordsPerMinute.toDouble(),
                        );
                        final sections = sectionMarkers(text).length;
                        return Text(
                          words == 0
                              ? 'Empty'
                              : '$words words${time.isEmpty ? '' : ' · $time'}${sections == 0 ? '' : ' · $sections ${sections == 1 ? 'section' : 'sections'}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        );
                      },
                    ),
                  ),
                  if (!demo) ...[
                    Tooltip(
                      message: 'Insert Section (${mod}K)',
                      child: compact
                          ? IconButton.outlined(
                              onPressed: onInsertSection,
                              icon: const Icon(
                                Icons.horizontal_split,
                                size: 16,
                              ),
                              visualDensity: VisualDensity.compact,
                            )
                          : OutlinedButton.icon(
                              onPressed: onInsertSection,
                              icon: const Icon(
                                Icons.horizontal_split,
                                size: 16,
                              ),
                              label: const Text('Insert Section'),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (!demo)
                    ValueListenableBuilder<bool>(
                      valueListenable: dirty,
                      builder: (context, dirty, _) => ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => Row(
                          children: [
                            TextButton(
                              onPressed: dirty ? onCancel : null,
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed:
                                  dirty &&
                                      cleanScript(controller.text).isNotEmpty
                                  ? onSave
                                  : null,
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  readOnly: demo,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 18, height: 1.45),
                  onChanged: (_) => onEdited(),
                  decoration: InputDecoration(
                    hintText: 'Script: paste or type it here…',
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
      },
    );
  }
}

// --- inspector ---------------------------------------------------------------

class _Inspector extends ConsumerWidget {
  const _Inspector({
    required this.caretWord,
    required this.dirty,
    required this.onStart,
    required this.onPreferences,
  });
  final ValueNotifier<int> caretWord;
  final ValueNotifier<bool> dirty;
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
    // Audio mode only starts with a recording that has been checked and can be read.
    final audioBlock = mode == PromptControlMode.recordedAudio
        ? audioStartBlocker(ref.watch(audioCheckProvider))
        : null;
    // A script the free plan can't present: Start shows a lock and opens the plans.
    ref.watch(studioProvider.select((s) => s.scriptRevision));
    final locked = !ref.watch(proProvider.select((p) => p.canPresent(ref.read(studioProvider.notifier).currentId)));

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
                    const SizedBox(height: 8),
                    const _SpeakerHint(),
                  ],
                  const SizedBox(height: 22),
                  const _SectionTitle('Position'),
                  const PositionPicker(),
                  const _PositionTip(),
                  const SizedBox(height: 22),
                  const _SectionTitle('Text', trailing: ResetTextButton()),
                  const PromptTextControls(collapsible: true),
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
                  // Starting uses the saved script, so unsaved edits come first.
                  ValueListenableBuilder<bool>(
                    valueListenable: dirty,
                    builder: (context, unsaved, _) => FilledButton.icon(
                      onPressed: empty || unsaved || audioBlock != null
                          ? null
                          : onStart,
                      icon: Icon(locked ? Icons.lock_outline : Icons.play_arrow),
                      label: Text('Start  $startKey'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  if (locked && audioBlock == null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Needs Pro. You\'ve used your $freeScriptLimit free scripts.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: proText(context)),
                    ),
                  ],
                  if (audioBlock != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      audioBlock,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
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
  const _SectionTitle(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              letterSpacing: 1,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _AudioChooser extends ConsumerWidget {
  const _AudioChooser();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(audioPathProvider);
    final check = ref.watch(audioCheckProvider);
    final scheme = Theme.of(context).colorScheme;
    final unreadable =
        check.hasValue &&
        check.requireValue.readiness == AudioReadiness.unreadable;
    final checking = path != null && check.isLoading;
    final seconds = check.hasValue ? check.requireValue.seconds : null;
    final detail = path == null
        ? 'Pick the recording to follow.'
        : checking
        ? 'Checking the recording…'
        : unreadable
        ? 'Can\'t read this recording. It may be damaged, moved, or in a format EchoPrompter can\'t play.'
        : '${seconds == null ? '' : '${formatSeconds(seconds)} · '}Plays out loud while EchoPrompter follows it through the microphone.';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: unreadable
            ? scheme.errorContainer.withValues(alpha: 0.4)
            : scheme.surfaceContainerHigh,
        border: path == null ? Border.all(color: scheme.outlineVariant) : null,
      ),
      child: Row(
        children: [
          checking
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Icon(
                  unreadable ? Icons.warning_amber_rounded : Icons.graphic_eq,
                  color: unreadable ? scheme.error : null,
                ),
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
                  detail,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: unreadable ? scheme.error : scheme.onSurfaceVariant,
                  ),
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

/// Audio mode follows the file by listening to it, so it can't be played into a headset.
class _SpeakerHint extends StatelessWidget {
  const _SpeakerHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Play the audio on your speakers, not a headset, so the microphone can hear it.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
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
