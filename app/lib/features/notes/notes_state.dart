import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/saved_script.dart';
import '../../services/storage/script_io.dart';
import '../../services/storage/script_library.dart';

const notesHistoryKey = 'EchoPrompter.noteHistory.v1';

final notesLibraryProvider = Provider<ScriptLibrary>((_) => throw UnimplementedError());

/// Which list Script Studio's sidebar shows. Notes are macOS and Windows only.
enum LibraryTab { scripts, notes }

class LibraryTabNotifier extends Notifier<LibraryTab> {
  @override
  LibraryTab build() => LibraryTab.scripts;
  void show(LibraryTab t) => state = t;
}

final libraryTabProvider = NotifierProvider<LibraryTabNotifier, LibraryTab>(LibraryTabNotifier.new);

/// `- [ ] item` or `- [x] item`: group 1 is everything up to the box, 2 its mark, 3 the rest.
final _checkboxLine = RegExp(r'^(\s*[-*]\s+\[)([ xX])(\].*)$');
final _bulletLine = RegExp(r'^\s*[-*]\s+(.*)$');

/// How a line of a note is shown.
sealed class NoteLine {
  const NoteLine();
}

class CheckLine extends NoteLine {
  const CheckLine(this.index, this.text, this.done);
  final int index;
  final String text;
  final bool done;
}

class BulletLine extends NoteLine {
  const BulletLine(this.text);
  final String text;
}

class TextLine extends NoteLine {
  const TextLine(this.text);
  final String text;
}

/// A note's text as lines: checkboxes, bullets and plain text.
List<NoteLine> parseNote(String body) {
  final lines = body.replaceAll('\r\n', '\n').split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      if (_checkboxLine.firstMatch(lines[i]) case final m?)
        CheckLine(i, lines[i].substring(m.end - m[3]!.length + 1).trim(), m[2] != ' ')
      else if (_bulletLine.firstMatch(lines[i]) case final m?)
        BulletLine(m[1]!)
      else
        TextLine(lines[i]),
  ];
}

/// (ticked, total) checkboxes in [body]; total is 0 for a note without a checklist.
(int, int) checklistProgress(String body) {
  var done = 0, total = 0;
  for (final l in parseNote(body)) {
    if (l is CheckLine) {
      total++;
      if (l.done) done++;
    }
  }
  return (done, total);
}

class NotesState {
  const NotesState({required this.history, this.currentId, this.editing = false});

  /// The 20 most recent notes; older files stay in the folder, and Import opens them.
  final List<SavedScript> history;
  final String? currentId;

  /// The editor is open (a new note, or Edit on the open one).
  final bool editing;

  SavedScript? get current => history.where((n) => n.id == currentId).firstOrNull;

  NotesState copyWith({List<SavedScript>? history, String? Function()? currentId, bool? editing}) => NotesState(
    history: history ?? this.history,
    currentId: currentId == null ? this.currentId : currentId(),
    editing: editing ?? this.editing,
  );
}

class NotesNotifier extends Notifier<NotesState> {
  @override
  NotesState build() {
    final history = ref.read(notesLibraryProvider).load();
    return NotesState(history: history, currentId: history.firstOrNull?.id);
  }

  void open(SavedScript n) => state = state.copyWith(currentId: () => n.id, editing: false);

  /// A blank note in the editor; it is saved with Save.
  void startNew() => state = state.copyWith(currentId: () => null, editing: true);

  void setEditing(bool editing) => state = state.copyWith(editing: editing);

  /// Saves [body] under [title]. Notes are stored as typed: unlike scripts, they keep their `- [ ]` markers.
  Future<void> save({required String title, required String body}) async {
    final id = state.currentId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final existing = state.current;
    final note = SavedScript(
      id: id,
      body: body,
      savedAt: DateTime.now(),
      fileName: existing?.fileName,
      customTitle: title.trim().isEmpty ? null : title.trim(),
    );
    final history = await ref.read(notesLibraryProvider).save(state.history, note);
    state = state.copyWith(history: history, currentId: () => id, editing: false);
  }

  /// Ticks or unticks the checkbox on [line] of the open note and saves it straight away.
  Future<void> toggleLine(int line) async {
    final note = state.current;
    if (note == null) return;
    final lines = note.body.replaceAll('\r\n', '\n').split('\n');
    final m = _checkboxLine.firstMatch(lines[line]);
    if (m == null) return;
    lines[line] = '${m[1]}${m[2] == ' ' ? 'x' : ' '}${m[3]}';
    await save(title: note.customTitle ?? '', body: lines.join('\n'));
  }

  Future<void> importNote(String fileName, String text) async {
    state = state.copyWith(currentId: () => null);
    await save(title: titleFromFileName(fileName), body: text);
  }

  Future<void> delete(SavedScript n) async {
    final history = await ref.read(notesLibraryProvider).delete(state.history, n);
    final gone = n.id == state.currentId;
    state = state.copyWith(
      history: history,
      currentId: gone ? () => history.firstOrNull?.id : null,
      editing: gone ? false : null,
    );
  }
}

final notesProvider = NotifierProvider<NotesNotifier, NotesState>(NotesNotifier.new);
