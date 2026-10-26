import 'dart:ui' show VoidCallback;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the menu bar can do in Script Studio. The Studio screen registers these while it is showing, so
/// the menu items route to the same actions as the toolbar and shortcuts, and are disabled otherwise
/// (while the prompter is open).
class StudioCommands {
  const StudioCommands({
    required this.newScript,
    required this.newNote,
    required this.importFile,
    required this.exportFile,
    required this.save,
    required this.insertSection,
    required this.start,
    required this.settings,
    required this.showScriptsFolder,
    required this.showNotesFolder,
    required this.deleteScript,
    required this.showScripts,
    required this.showNotes,
  });

  final VoidCallback newScript;
  final VoidCallback newNote;
  final VoidCallback importFile;
  final VoidCallback exportFile;
  final VoidCallback save;
  final VoidCallback insertSection;
  final VoidCallback start;
  final VoidCallback settings;
  final VoidCallback showScriptsFolder;
  final VoidCallback showNotesFolder;
  final VoidCallback deleteScript;
  final VoidCallback showScripts;
  final VoidCallback showNotes;
}

class StudioCommandsNotifier extends Notifier<StudioCommands?> {
  @override
  StudioCommands? build() => null;
  void set(StudioCommands? c) => state = c;
}

final studioCommandsProvider = NotifierProvider<StudioCommandsNotifier, StudioCommands?>(StudioCommandsNotifier.new);
