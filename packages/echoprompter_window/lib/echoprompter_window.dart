import 'dart:async';

import 'package:flutter/services.dart';

enum WindowPlacement { notch, corner, floating }

enum WindowCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Everything the native side needs to lay the single app window out as the
/// prompter. Sizes are in logical points/dips.
class PrompterWindowOptions {
  const PrompterWindowOptions({
    this.placement = WindowPlacement.floating,
    this.corner = WindowCorner.topRight,
    this.hideFromCapture = true,
    this.notchSize = const Size(560, 150),
    this.cornerSize = const Size(420, 240),
    this.floatingFrame,
  });

  final WindowPlacement placement;
  final WindowCorner corner;
  final bool hideFromCapture;
  final Size notchSize;
  final Size cornerSize;

  /// Saved floating frame, relative to the display's origin (top-left,
  /// y down). Null uses the default near the top centre.
  final Rect? floatingFrame;

  Map<String, Object?> toMap() => {
    'placement': placement.name,
    'corner': corner.name,
    'hideFromCapture': hideFromCapture,
    'notchWidth': notchSize.width,
    'notchHeight': notchSize.height,
    'cornerWidth': cornerSize.width,
    'cornerHeight': cornerSize.height,
    if (floatingFrame != null)
      'floatingFrame': [
        floatingFrame!.left,
        floatingFrame!.top,
        floatingFrame!.width,
        floatingFrame!.height,
      ],
  };
}

/// The window moved or was resized by the user while in floating/corner
/// placement. [frame] is relative to the display ([displayKey]).
class WindowFrameEvent {
  const WindowFrameEvent(this.displayKey, this.frame, this.snappedCorner, [this.notchHeight]);
  final String displayKey;
  final Rect frame;

  /// Set when a drag in Corner placement snapped to the nearest corner.
  final WindowCorner? snappedCorner;

  /// Set after the notch body was resized: height below the hardware notch.
  final double? notchHeight;
}

/// One row of the menu-bar / notification-area menu.
class TrayItem {
  const TrayItem(this.id, this.title, {this.enabled = true, this.checked = false}) : separator = false;
  const TrayItem.separator() : id = '', title = '', enabled = false, checked = false, separator = true;

  final String id;
  final String title;
  final bool enabled;
  final bool checked;
  final bool separator;

  Map<String, Object> toMap() => {
    'id': id,
    'title': title,
    'enabled': enabled,
    'checked': checked,
    'separator': separator,
  };
}

/// A system-wide shortcut. [key] is `space`, `up`, `down`, `left`, `right`,
/// `a`–`z` or `0`–`9`; [mods] are any of `ctrl`, `alt`, `shift`, `meta`
/// (⌘ on macOS, the Windows key on Windows).
class HotkeyBinding {
  const HotkeyBinding(this.id, this.key, this.mods);
  final String id;
  final String key;
  final Set<String> mods;

  Map<String, Object> toMap() => {'id': id, 'key': key, 'mods': mods.toList()};
}

/// Facade over the native window tricks: one window that switches between a
/// normal "Studio" configuration and a borderless, top-most "Prompter" one.
class EchoPrompterWindow {
  EchoPrompterWindow._();

  static const _channel = MethodChannel('com.echoprompter/window');
  static final _frames = StreamController<WindowFrameEvent>.broadcast();
  static final _trayActions = StreamController<String>.broadcast();
  static final _hotkeys = StreamController<String>.broadcast();
  static bool _wired = false;

  static Stream<WindowFrameEvent> get frameChanges {
    _wire();
    return _frames.stream;
  }

  /// The id of a [TrayItem] the user picked from the tray menu.
  static Stream<String> get trayActions {
    _wire();
    return _trayActions.stream;
  }

  /// The id of a [HotkeyBinding] the user pressed.
  static Stream<String> get hotkeys {
    _wire();
    return _hotkeys.stream;
  }

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'trayAction') {
        _trayActions.add(call.arguments as String);
        return;
      }
      if (call.method == 'hotkey') {
        _hotkeys.add(call.arguments as String);
        return;
      }
      if (call.method != 'frameChanged') return;
      final a = (call.arguments as Map).cast<String, Object?>();
      final f = (a['frame'] as List).cast<num>();
      final corner = a['corner'] as String?;
      _frames.add(WindowFrameEvent(
        a['display'] as String,
        Rect.fromLTWH(f[0].toDouble(), f[1].toDouble(), f[2].toDouble(), f[3].toDouble()),
        corner == null ? null : WindowCorner.values.byName(corner),
        (a['notchHeight'] as num?)?.toDouble(),
      ));
    });
  }

  /// Hides Studio chrome and shows the prompter overlay.
  static Future<void> enterPrompter(PrompterWindowOptions o) {
    _wire();
    return _channel.invokeMethod('enterPrompter', o.toMap());
  }

  /// Re-applies placement and capture settings without rebuilding widgets.
  static Future<void> update(PrompterWindowOptions o) =>
      _channel.invokeMethod('update', o.toMap());

  /// Restores the Studio frame and style.
  static Future<void> exitPrompter() => _channel.invokeMethod('exitPrompter');

  /// Window drag/resize driven by the native mouse position, so it stays
  /// correct while the window itself moves. Call [gestureBegin] on pan start,
  /// then [dragUpdate] or [resizeUpdate] on every update, then [gestureEnd].
  static Future<void> gestureBegin() => _channel.invokeMethod('gestureBegin');
  static Future<void> dragUpdate() => _channel.invokeMethod('dragUpdate');

  /// [edge] is any of `l`, `r`, `b` combined (e.g. `br`). In notch placement
  /// only `b` is meaningful and resizes the notch body.
  static Future<void> resizeUpdate(String edge) =>
      _channel.invokeMethod('resizeUpdate', edge);
  static Future<void> gestureEnd() => _channel.invokeMethod('gestureEnd');

  /// Shows the menu-bar (macOS) / notification-area (Windows) icon with
  /// [items], or removes it when [items] is null. Returns whether the icon is
  /// now showing, so callers never depend on a control that isn't there.
  static Future<bool> setTrayMenu(List<TrayItem>? items) async {
    _wire();
    try {
      return (await _channel.invokeMethod<bool>('setTrayMenu', {
            if (items != null) 'items': [for (final i in items) i.toMap()],
          })) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Registers system-wide shortcuts, replacing any registered before. Returns
  /// which ids succeeded; one can fail when another app already owns the keys.
  static Future<Map<String, bool>> registerHotkeys(List<HotkeyBinding> bindings) async {
    _wire();
    try {
      final r = await _channel.invokeMapMethod<String, bool>('registerHotkeys', {
        'bindings': [for (final b in bindings) b.toMap()],
      });
      return r ?? {};
    } on MissingPluginException {
      return {};
    }
  }

  static Future<void> unregisterHotkeys() async {
    try {
      await _channel.invokeMethod('unregisterHotkeys');
    } on MissingPluginException {
      // No native side (tests, unsupported platform): nothing to undo.
    }
  }

  /// Makes the window visible again after [exitPrompter] once Studio has been
  /// drawn. A no-op where the native side doesn't hide the window.
  static Future<void> revealStudio() async {
    try {
      await _channel.invokeMethod('revealStudio');
    } on MissingPluginException {
      // Nothing was hidden.
    }
  }

  /// Hides or re-shows the prompter window without leaving the session.
  static Future<void> setPrompterVisible(bool visible) =>
      _channel.invokeMethod('setPrompterVisible', visible);

  /// Whether this OS build can hide the window from capture. False on
  /// Windows older than 10 version 2004.
  static Future<bool> get supportsCaptureHiding async =>
      (await _channel.invokeMethod<bool>('supportsCaptureHiding')) ?? false;

  /// Whether the main display has a hardware notch (macOS only).
  static Future<bool> get hasHardwareNotch async =>
      (await _channel.invokeMethod<bool>('hasHardwareNotch')) ?? false;

  /// macOS: settings left behind by the Swift proof of concept. Empty
  /// elsewhere. Keys: placement, corner, hideFromCapture.
  static Future<Map<String, Object?>> legacyDefaults() async {
    try {
      return (await _channel.invokeMapMethod<String, Object?>('legacyDefaults')) ?? {};
    } on MissingPluginException {
      return {};
    }
  }
}
