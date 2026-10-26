import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/reading_time.dart';
import '../../core/script/saved_script.dart';
import '../../services/platform.dart';
import '../../services/storage/script_library.dart';
import '../../ui/discard_changes_dialog.dart';
import 'notes_state.dart';

/// Whether the note editor holds edits that aren't saved, so the sidebar can ask before leaving them.
class NoteDraftDirty extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) {
    if (v != state) state = v;
  }
}

final noteDraftDirtyProvider = NotifierProvider<NoteDraftDirty, bool>(NoteDraftDirty.new);

/// Save for the open note editor, so the menu bar's Save (⌘S) reaches it. Null when no editor is open.
class NoteEditorSave extends Notifier<Future<void> Function()?> {
  @override
  Future<void> Function()? build() => null;
  void set(Future<void> Function()? f) => state = f;
}

final noteEditorSaveProvider = NotifierProvider<NoteEditorSave, Future<void> Function()?>(NoteEditorSave.new);

/// True when nothing unsaved would be lost, or the user agreed to lose it.
Future<bool> canLeaveNoteDraft(BuildContext context, WidgetRef ref) async {
  if (!ref.read(noteDraftDirtyProvider)) return true;
  if (!await confirmDiscardChanges(context, what: 'note')) return false;
  ref.read(noteDraftDirtyProvider.notifier).set(false);
  return true;
}

String _noteMeta(SavedScript n) {
  final (done, total) = checklistProgress(n.body);
  return total == 0 ? friendlyDate(n.savedAt) : '${friendlyDate(n.savedAt)} · $done of $total done';
}

/// Sidebar list of notes: the 20 most recent, newest first.
class NoteSidebar extends ConsumerWidget {
  const NoteSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = theme.textTheme.labelMedium?.copyWith(letterSpacing: 1, color: scheme.onSurfaceVariant);

    Future<void> delete(SavedScript n) async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete “${n.title}”?'),
          content: const Text('It is removed from your notes folder too. This can\'t be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok == true) await ref.read(notesProvider.notifier).delete(n);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
        child: Row(children: [
          Text('RECENT NOTES', style: label),
          if (notes.history.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
              child: Text('${notes.history.length}', style: label?.copyWith(letterSpacing: 0, color: scheme.onSurface)),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'New note (${isMacOS ? '⌥⌘N' : 'Ctrl+Alt+N'})',
            icon: const Icon(Icons.add),
            onPressed: () async {
              if (!await canLeaveNoteDraft(context, ref)) return;
              ref.read(notesProvider.notifier).startNew();
            },
          ),
        ]),
      ),
      Expanded(
        child: notes.history.isEmpty
            ? Center(child: Text('No notes yet', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)))
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  for (final n in notes.history)
                    _NoteRow(
                      note: n,
                      current: n.id == notes.currentId,
                      onTap: () async {
                        if (!await canLeaveNoteDraft(context, ref)) return;
                        ref.read(notesProvider.notifier).open(n);
                      },
                      onDelete: () => delete(n),
                    ),
                  if (notes.history.length >= ScriptLibrary.maxEntries)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                      child: Text(
                        'Showing your ${ScriptLibrary.maxEntries} most recent notes. Older ones are kept in the EchoPrompter Notes folder; use Import to open one.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
      ),
    ]);
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note, required this.current, required this.onTap, required this.onDelete});
  final SavedScript note;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = note.preview;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: current ? scheme.primary.withValues(alpha: 0.14) : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.checklist_rounded, size: 18, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(note.title.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    if (preview.isNotEmpty) ...[
                      Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                    ],
                    Text(_noteMeta(note), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz, size: 18),
                onSelected: (_) => onDelete(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: scheme.error))),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The main area while Notes is showing: an empty state, the open note, or the editor.
class NotesPane extends ConsumerWidget {
  const NotesPane({super.key, required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesProvider);
    if (notes.editing) return _NoteEditor(key: ValueKey(notes.currentId ?? 'new'), note: notes.current);
    final note = notes.current;
    if (note == null) return _EmptyNotes(onImport: onImport, hasNotes: notes.history.isNotEmpty);
    return _NoteReader(note: note);
  }
}

class _EmptyNotes extends ConsumerWidget {
  const _EmptyNotes({required this.onImport, required this.hasNotes});
  final VoidCallback onImport;
  final bool hasNotes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final newKey = isMacOS ? '⌥⌘N' : 'Ctrl+Alt+N';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
              child: Icon(Icons.checklist_rounded, size: 30, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(hasNotes ? 'Choose a note' : 'Keep notes for reference', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              hasNotes
                  ? 'Pick a note from the list, or start a new one.'
                  : 'Talking points, checklists and anything you want close at hand. Notes are never read aloud or tracked, and they\'re saved in Documents › EchoPrompter Notes.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
              FilledButton(onPressed: ref.read(notesProvider.notifier).startNew, child: Text('New Note  $newKey')),
              OutlinedButton(onPressed: onImport, child: Text('Import…  ${isMacOS ? '⌘O' : 'Ctrl+O'}')),
            ]),
            if (!hasNotes) ...[
              const SizedBox(height: 14),
              Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Tip: start a line with '),
                  TextSpan(text: '- [ ]', style: TextStyle(fontFamily: 'Menlo', color: scheme.onSurface)),
                  const TextSpan(text: ' for a checkbox, or '),
                  TextSpan(text: '-', style: TextStyle(fontFamily: 'Menlo', color: scheme.onSurface)),
                  const TextSpan(text: ' for a bullet.'),
                ]),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The open note, with checkboxes you can tick; ticking saves at once.
class _NoteReader extends ConsumerWidget {
  const _NoteReader({required this.note});
  final SavedScript note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = parseNote(note.body);
    final (done, total) = checklistProgress(note.body);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(40, 24, 40, 32),
          children: [
            Row(children: [
              Expanded(child: Text(note.title.trim(), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600))),
              OutlinedButton.icon(
                onPressed: () => ref.read(notesProvider.notifier).setEditing(true),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit'),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Text(_noteMeta(note), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (total > 0) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(value: done / total, minHeight: 4, borderRadius: BorderRadius.circular(2)),
                ),
              ],
            ]),
            const SizedBox(height: 14),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: 16),
            for (final l in lines)
              switch (l) {
                CheckLine() => InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => ref.read(notesProvider.notifier).toggleLine(l.index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Checkbox(
                        value: l.done,
                        visualDensity: VisualDensity.compact,
                        onChanged: (_) => ref.read(notesProvider.notifier).toggleLine(l.index),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          l.text,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: l.done ? scheme.onSurfaceVariant : null,
                            decoration: l.done ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
                BulletLine() => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 24, child: Text('•', style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant))),
                    Expanded(child: Text(l.text, style: theme.textTheme.bodyLarge)),
                  ]),
                ),
                TextLine() => l.text.trim().isEmpty
                    ? const SizedBox(height: 12)
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
                        child: Text(l.text, style: theme.textTheme.bodyLarge),
                      ),
              },
          ],
        ),
      ),
    );
  }
}

/// Title and text with Cancel and Save. Edits are a draft until Save, as for scripts.
class _NoteEditor extends ConsumerStatefulWidget {
  const _NoteEditor({super.key, required this.note});
  final SavedScript? note;

  @override
  ConsumerState<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<_NoteEditor> {
  late final _title = TextEditingController(text: widget.note?.customTitle ?? '');
  late final _body = TextEditingController(text: widget.note?.body ?? '');
  final _bodyFocus = FocusNode();

  bool get _dirty => _title.text.trim() != (widget.note?.customTitle ?? '').trim() || _body.text != (widget.note?.body ?? '');
  bool get _canSave => _dirty && _body.text.trim().isNotEmpty;

  void _changed() {
    ref.read(noteDraftDirtyProvider.notifier).set(_dirty);
    setState(() {});
  }

  late final NoteEditorSave _saveSlot = ref.read(noteEditorSaveProvider.notifier);

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _body.addListener(_changed);
    Future.microtask(() => _saveSlot.set(_save));
  }

  @override
  void dispose() {
    Future.microtask(() => _saveSlot.set(null));
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_canSave) return;
    await ref.read(notesProvider.notifier).save(title: _title.text, body: _body.text);
    ref.read(noteDraftDirtyProvider.notifier).set(false);
  }

  Future<void> _cancel() async {
    if (_dirty && !await confirmDiscardChanges(context, what: 'note')) return;
    ref.read(noteDraftDirtyProvider.notifier).set(false);
    ref.read(notesProvider.notifier).setEditing(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = TextStyle(fontFamily: 'Menlo', color: scheme.onSurface);
    final n = _title.text.characters.length;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyS, meta: isMacOS, control: !isMacOS): _save,
      },
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _title,
                inputFormatters: [LengthLimitingTextInputFormatter(SavedScript.maxTitleLength)],
                maxLines: 1,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  hintText: 'Title',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  suffixText: n >= 20 ? '$n/${SavedScript.maxTitleLength}' : null,
                  suffixStyle: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '- [ ]', style: mono),
                      const TextSpan(text: ' checkbox  ·  '),
                      TextSpan(text: '-', style: mono),
                      const TextSpan(text: ' bullet'),
                    ]),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                TextButton(onPressed: _cancel, child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _canSave ? _save : null, child: const Text('Save')),
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _body,
                  focusNode: _bodyFocus,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                  decoration: InputDecoration(
                    hintText: 'Note: type or paste it here…',
                    filled: true,
                    fillColor: scheme.surfaceContainerLow,
                    contentPadding: const EdgeInsets.all(16),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
