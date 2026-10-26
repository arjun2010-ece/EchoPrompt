import 'platform.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:echoprompter_window/echoprompter_window.dart';
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

const settingsKey = 'EchoPrompter.settings.v2';

final prefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError());
final libraryProvider = Provider<ScriptLibrary>((_) => throw UnimplementedError());
final entitlementsProvider = Provider<Entitlements>((_) => const UnlockedEntitlements());
final analyticsProvider = Provider((_) => AnalyticsService());

/// `~/Documents/EchoPrompter Scripts` on desktop; app documents on mobile.
Future<Directory> scriptsDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'EchoPrompter Scripts'));
}

/// `~/Documents/EchoPrompter Notes` (macOS and Windows): reference notes, kept apart from scripts.
Future<Directory> notesDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'EchoPrompter Notes'));
}

String jsonEncodeSettings(PromptSettings s) => jsonEncode(s.toJson());

class SettingsNotifier extends Notifier<PromptSettings> {
  @override
  PromptSettings build() {
    final raw = ref.read(prefsProvider).getString(settingsKey);
    if (raw == null) return const PromptSettings();
    // The control mode is per session: every launch starts in Normal.
    return PromptSettings.fromJson(jsonDecode(raw) as Map<String, Object?>)
        .copyWith(mode: PromptControlMode.normal);
  }

  void update(PromptSettings Function(PromptSettings) f) {
    state = f(state);
    ref.read(prefsProvider).setString(settingsKey, jsonEncode(state.toJson()));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, PromptSettings>(SettingsNotifier.new);

/// Puts the options under "Text" back to their defaults. Mode, position, mirror,
/// screen-sharing visibility and shortcuts are never touched.
extension ResetTextSettings on SettingsNotifier {
  void resetText() {
    const d = PromptSettings();
    update((c) => c.copyWith(
      fontSize: d.fontSize,
      lineSpacing: d.lineSpacing,
      opacity: d.opacity,
      readingGuide: d.readingGuide,
      showProgress: d.showProgress,
      showSections: d.showSections,
      margins: d.margins,
      font: d.font,
    ));
  }
}

class StudioState {
  const StudioState({
    required this.script,
    required this.history,
    required this.sessionId,
    this.title = '',
    this.presenting = false,
    this.scriptRevision = 0,
    this.resumeWordIndex,
  });
  final String script;
  final List<SavedScript> history;

  /// Saved title of the open script; empty when it has none (the first line is shown instead).
  final String title;

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
    String? title,
    List<SavedScript>? history,
    int? sessionId,
    bool? presenting,
    int? scriptRevision,
    int? Function()? resumeWordIndex,
  }) => StudioState(
    script: script ?? this.script,
    title: title ?? this.title,
    history: history ?? this.history,
    sessionId: sessionId ?? this.sessionId,
    presenting: presenting ?? this.presenting,
    scriptRevision: scriptRevision ?? this.scriptRevision,
    resumeWordIndex: resumeWordIndex == null ? this.resumeWordIndex : resumeWordIndex(),
  );
}

class StudioNotifier extends Notifier<StudioState> {
  static const welcome =
      'Welcome to EchoPrompter.\n\n'
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

  Timer? _saveTimer;
  Future<void> _saving = Future.value();

  /// Typing saves the script to the list once it pauses, so a new script
  /// appears as soon as it has content rather than only after Start.
  void setScript(String text) {
    state = state.copyWith(script: text);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), flush);
  }

  /// Replaces the script with [text] from an explicit Save and stores it at once.
  Future<void> commitScript(String text, {String? title}) {
    state = state.copyWith(script: text, title: title);
    return flush();
  }

  /// Saves pending edits now. Blank text and the untouched welcome text are
  /// placeholders, not scripts, so they are never saved.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final text = state.script;
    if (text.trim().isEmpty || (_currentId == null && text == welcome)) return _saving;
    return _persist(_currentId ??= DateTime.now().microsecondsSinceEpoch.toString(), text, state.title);
  }

  /// Saves run one after another so each sees the previous save's history and
  /// file name.
  Future<void> _persist(String id, String text, String title) => _saving = _saving.then((_) async {
    final existing = state.history.where((s) => s.id == id).firstOrNull;
    if (existing != null && existing.body == text && (existing.customTitle?.trim() ?? '') == title.trim()) return;
    final script = SavedScript(
      id: id,
      body: text,
      savedAt: DateTime.now(),
      fileName: existing?.fileName,
      customTitle: title.trim().isEmpty ? null : title.trim(),
    );
    final history = await ref.read(libraryProvider).save(state.history, script);
    state = state.copyWith(history: history);
  });

  /// Saves the script and starts a new presentation session.
  Future<void> start() async {
    final id = _currentId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final script = SavedScript(id: id, body: state.script, savedAt: DateTime.now());
    if (!ref.read(entitlementsProvider).canStartPrompter(script)) return;
    // Saving is disk I/O; don't hold up the screen change for it.
    unawaited(flush());
    state = state.copyWith(sessionId: state.sessionId + 1, presenting: true);
    ref.read(analyticsProvider).log('teleprompter_start', {
      'mode': ref.read(settingsProvider).mode.name,
      'words_bucket': AnalyticsService.wordsBucket(state.script.split(RegExp(r'\s+')).length),
    });
  }

  void load(SavedScript s) {
    flush();
    _currentId = s.id;
    state = state.copyWith(
      script: s.body,
      title: s.customTitle ?? '',
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  /// Opens the built-in demo script; like the welcome text it is never saved.
  void loadDemo() {
    flush();
    _currentId = null;
    state = state.copyWith(
      script: welcome,
      title: '',
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  /// Starts an empty script; it is saved on the first Start.
  void newScript() {
    flush();
    _currentId = null;
    state = state.copyWith(
      script: '',
      title: '',
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  /// Opens a copy of [s] as a new, unsaved script.
  void duplicate(SavedScript s) {
    flush();
    _currentId = null;
    state = state.copyWith(
      script: s.body,
      title: s.customTitle ?? '',
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
  }

  Future<void> delete(SavedScript s) async {
    if (s.id == _currentId) _saveTimer?.cancel();
    await _saving;
    final history = await ref.read(libraryProvider).delete(state.history, s);
    if (s.id == _currentId) _currentId = null;
    state = state.copyWith(history: history);
  }

  Future<void> deleteMany(List<SavedScript> scripts) async {
    for (final s in scripts) {
      await delete(s);
    }
  }

  /// Leaves the prompter (desktop restores the Studio window). [wordIndex] is
  /// where the presenter had reached.
  void stopPresenting({int? wordIndex}) =>
      state = state.copyWith(presenting: false, resumeWordIndex: () => wordIndex);

  /// Loads an imported script as a new, unsaved script.
  Future<void> importScript(String body, {String? title}) async {
    flush();
    _currentId = null;
    state = state.copyWith(
      script: body,
      title: title ?? '',
      presenting: false,
      scriptRevision: state.scriptRevision + 1,
      resumeWordIndex: () => null,
    );
    flush();
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

/// Pixels of text still to scroll in Normal mode, in steps of 10 so it changes a few times a second at
/// most. The progress line turns it into time left.
class ScrollRemainingNotifier extends Notifier<double> {
  @override
  double build() => 0;
  void set(double v) {
    final stepped = (v / 10).round() * 10.0;
    if (stepped != state) state = stepped;
  }
}

final scrollRemainingProvider = NotifierProvider<ScrollRemainingNotifier, double>(ScrollRemainingNotifier.new);

/// Global shortcuts, persisted and layered over the platform defaults.
class ShortcutsNotifier extends Notifier<Map<ShortcutAction, ShortcutBinding>> {
  static const key = 'EchoPrompter.shortcuts.v1';

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
    return await EchoPrompterWindow.hasHardwareNotch;
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
