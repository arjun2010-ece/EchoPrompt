import 'dart:convert';
import 'dart:ui';

import 'package:echoprompt_window/echoprompt_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings/prompt_settings.dart';

/// Maps app settings to native window options and remembers the floating
/// frame per display.
class PrompterWindow {
  PrompterWindow(this._prefs);
  final SharedPreferences _prefs;

  static const _framesKey = 'EchoPrompt.floatingFrames.v1';
  String? _display;

  Map<String, List<double>> _frames() {
    final raw = _prefs.getString(_framesKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).map(
      (k, v) => MapEntry(k as String, (v as List).cast<num>().map((e) => e.toDouble()).toList()),
    );
  }

  PrompterWindowOptions options(PromptSettings s) {
    final saved = _display == null ? null : _frames()[_display];
    return PrompterWindowOptions(
      placement: WindowPlacement.values.byName(s.placement.name),
      corner: WindowCorner.values.byName(s.corner.name),
      hideFromCapture: s.hideFromCapture,
      notchSize: s.notchSize,
      cornerSize: s.cornerSize,
      floatingFrame: saved == null ? null : Rect.fromLTWH(saved[0], saved[1], saved[2], saved[3]),
    );
  }

  Future<void> enter(PromptSettings s) => EchoPromptWindow.enterPrompter(options(s));
  Future<void> update(PromptSettings s) => EchoPromptWindow.update(options(s));
  Future<void> exit() => EchoPromptWindow.exitPrompter();

  /// Persists a user-moved/resized floating frame. Corner snaps are returned
  /// so the caller can update the corner setting.
  void onFrame(WindowFrameEvent e, PromptSettings s) {
    _display = e.displayKey;
    if (s.placement != PromptPlacement.floating) return;
    final frames = _frames()
      ..[e.displayKey] = [e.frame.left, e.frame.top, e.frame.width, e.frame.height];
    _prefs.setString(_framesKey, jsonEncode(frames));
  }
}
