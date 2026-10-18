import 'platform.dart';
import 'dart:convert';
import 'dart:io';

import 'package:echoprompt_window/echoprompt_window.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/entitlements/entitlements.dart';
import '../core/script/saved_script.dart';
import '../core/shortcuts/shortcut_binding.dart';
import '../core/settings/prompt_settings.dart';
import 'analytics/analytics_service.dart';
import 'storage/script_library.dart';

const settingsKey = 'EchoPrompt.settings.v2';

final prefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError());
final libraryProvider = Provider<ScriptLibrary>((_) => throw UnimplementedError());
final entitlementsProvider = Provider<Entitlements>((_) => const UnlockedEntitlements());
final analyticsProvider = Provider((_) => AnalyticsService());

/// `~/Documents/EchoPrompt Scripts` on desktop; app documents on mobile.
Future<Directory> scriptsDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'EchoPrompt Scripts'));
}

String jsonEncodeSettings(PromptSettings s) => jsonEncode(s.toJson());

class SettingsNotifier extends Notifier<PromptSettings> {
  @override
  PromptSettings build() {
    final raw = ref.read(prefsProvider).getString(settingsKey);
    if (raw == null) return const PromptSettings();
    return PromptSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  void update(PromptSettings Function(PromptSettings) f) {
    state = f(state);
    ref.read(prefsProvider).setString(settingsKey, jsonEncode(state.toJson()));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, PromptSettings>(SettingsNotifier.new);

class StudioState {
  const StudioState({
    required this.script,
    required this.history,
    required this.sessionId,
    this.presenting = false,
    this.scriptRevision = 0,
    this.resumeWordIndex,
  });
  final String script;
  final List<SavedScript> history;

  /// Desktop: the window is currently in prompter configuration.
  final bool presenting;

  /// Regenerated on every Start; the only signal that resets scroll,
  /// highlighting and playback.
  final int sessionId;

  /// Bumped when the script is replaced from outside the editor (load, new,
  /// import) so the editor knows to reload its text. Typing does not bump it.
  final int scriptRevision;

  /// Word the presenter had reached when they left the prompter, so Studio can
  /// put the caret there. Null before the first session.
  final int? resumeWordIndex;

  StudioState copyWith({
    String? script,
    List<SavedScript>? history,
    int? sessionId,
    bool? presenting,
    int? scriptRevision,
    int? Function()? resumeWordIndex,
  }) => StudioState(
    script: script ?? this.script,
    history: history ?? this.history,
    sessionId: sessionId ?? this.sessionId,
    presenting: presenting ?? this.presenting,
    scriptRevision: scriptRevision ?? this.scriptRevision,
    resumeWordIndex: resumeWordIndex == null ? this.resumeWordIndex : resumeWordIndex(),
  );
}

class StudioNotifier extends Notifier<StudioState> {
  static const welcome =
      'Welcome to EchoPrompt.\n\n'
      'Replace this text with your own script, or press Import to open a file. '
      'The preview on the right shows exactly how your words will look.\n\n'
      'When you are ready, press Start. The prompter floats above every other '
      'app, so you can read while you present, and it stays hidden from screen '
      'sharing and recordings.\n\n'
      'Try the Top center position: placing your words right under the camera '
      'helps you keep eye contact with your audience.';
  String? _currentId;

  @override
  StudioState build() => StudioState(
    script: welcome,
    history: ref.read(libraryProvider).load(),
    sessionId: 0,
  );

  /// Id of the saved script being edited, if any.
  String? get currentId => _currentId;

  void setScript(String text) => state = state.copyWith(script: text);

  /// Saves the script and starts a new presentation session.
  Future<void> start() async {
    final lib = ref.read(libraryProvider);
    final existing = state.history.where((s) => s.id == _currentId).firstOrNull;
    final script = SavedScript(
      id: _currentId ??= DateTime.now().microsecondsSinceEpoch.toString(),
      body: state.script,
      savedAt: DateTime.now(),
      fileName: existing?.fileName,
    );
    if (!ref.read(entitlementsProvider).canStartPrompter(script)) return;
    final history = await lib.save(state.history, script);
    state = state.copyWith(history: history, sessionId: state.sessionId + 1, presenting: true);
    ref.read(analyticsProvider).log('teleprompter_start', {
      'mode': ref.read(settingsProvider).mode.name,
      'words_bucket': AnalyticsService.wordsBucket(state.script.split(RegExp(r'\s+')).length),
    });
  }

  void load(SavedScript s) {
    _currentId = s.id;
    state = state.copyWith(
      script: s.body,
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  /// Starts an empty script; it is saved on the first Start.
  void newScript() {
    _currentId = null;
    state = state.copyWith(
      script: '',
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  /// Opens a copy of [s] as a new, unsaved script.
  void duplicate(SavedScript s) {
    _currentId = null;
    state = state.copyWith(
      script: s.body,
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  Future<void> delete(SavedScript s) async {
    final history = await ref.read(libraryProvider).delete(state.history, s);
    if (s.id == _currentId) _currentId = null;
    state = state.copyWith(history: history);
  }

  /// Leaves the prompter (desktop restores the Studio window). [wordIndex] is
  /// where the presenter had reached.
  void stopPresenting({int? wordIndex}) =>
      state = state.copyWith(presenting: false, resumeWordIndex: () => wordIndex);

  /// Loads an imported script as a new, unsaved script.
  Future<void> importScript(String body) async {
    _currentId = null;
    state = state.copyWith(
      script: body,
      presenting: false,
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }
}

/// Word index nearest the reading line in Normal mode, so leaving the prompter
/// can put the Studio caret where the presenter stopped. Voice and Audio modes
/// have this in their reading progress instead.
class ReadingWordNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int v) {
    if (v != state) state = v;
  }
}

final readingWordProvider = NotifierProvider<ReadingWordNotifier, int>(ReadingWordNotifier.new);

/// Global shortcuts, persisted and layered over the platform defaults.
class ShortcutsNotifier extends Notifier<Map<ShortcutAction, ShortcutBinding>> {
  static const key = 'EchoPrompt.shortcuts.v1';

  @override
  Map<ShortcutAction, ShortcutBinding> build() =>
      decodeShortcuts(ref.read(prefsProvider).getString(key), mac: isMacOS);

  void set(ShortcutAction a, ShortcutBinding b) {
    state = {...state, a: b};
    ref.read(prefsProvider).setString(key, encodeShortcuts(state));
  }

  void reset() {
    state = defaultShortcuts(mac: isMacOS);
    ref.read(prefsProvider).remove(key);
  }
}

final shortcutsProvider =
    NotifierProvider<ShortcutsNotifier, Map<ShortcutAction, ShortcutBinding>>(ShortcutsNotifier.new);

/// Whether the main display has a hardware camera notch (macOS only).
final hasNotchProvider = FutureProvider<bool>((_) async {
  if (!isMacOS) return false;
  try {
    return await EchoPromptWindow.hasHardwareNotch;
  } on MissingPluginException {
    return false;
  }
});

class AudioPathNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? path) => state = path;
}

/// The reference audio file for Recorded-audio mode.
final audioPathProvider = NotifierProvider<AudioPathNotifier, String?>(AudioPathNotifier.new);

final studioProvider = NotifierProvider<StudioNotifier, StudioState>(StudioNotifier.new);
