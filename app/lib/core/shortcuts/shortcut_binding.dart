import 'dart:convert';

/// What a global shortcut does while the prompter is open.
enum ShortcutAction {
  playPause,
  slower,
  faster,
  restart,
  backToStudio,
}

enum ShortcutMod { ctrl, alt, shift, meta }

extension ShortcutActionLabel on ShortcutAction {
  String get label => switch (this) {
    ShortcutAction.playPause => 'Play / pause / toggle listening',
    ShortcutAction.slower => 'Slower',
    ShortcutAction.faster => 'Faster',
    ShortcutAction.restart => 'Restart from the beginning',
    ShortcutAction.backToStudio => 'Back to Script Studio',
  };
}

/// Keys a global shortcut may use. Names are shared with the native plugins.
final List<String> supportedShortcutKeys = [
  'space',
  'up',
  'down',
  'left',
  'right',
  for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++) String.fromCharCode(c),
  for (var d = 0; d <= 9; d++) '$d',
];

/// One key plus modifiers, e.g. Ctrl+Alt+Space.
class ShortcutBinding {
  const ShortcutBinding(this.key, this.mods);

  final String key;
  final Set<ShortcutMod> mods;

  /// A global shortcut needs a modifier, otherwise it would hijack typing.
  bool get isValid => mods.isNotEmpty && supportedShortcutKeys.contains(key);

  /// Human-readable, e.g. `⌃⌥Space` on macOS and `Ctrl+Alt+Space` elsewhere.
  String label({required bool mac}) {
    final keyLabel = switch (key) {
      'space' => 'Space',
      'up' => '↑',
      'down' => '↓',
      'left' => '←',
      'right' => '→',
      _ => key.toUpperCase(),
    };
    const order = [ShortcutMod.ctrl, ShortcutMod.alt, ShortcutMod.shift, ShortcutMod.meta];
    final active = [for (final m in order) if (mods.contains(m)) m];
    if (mac) {
      const glyph = {
        ShortcutMod.ctrl: '⌃',
        ShortcutMod.alt: '⌥',
        ShortcutMod.shift: '⇧',
        ShortcutMod.meta: '⌘',
      };
      return '${active.map((m) => glyph[m]).join()}$keyLabel';
    }
    const word = {
      ShortcutMod.ctrl: 'Ctrl',
      ShortcutMod.alt: 'Alt',
      ShortcutMod.shift: 'Shift',
      ShortcutMod.meta: 'Win',
    };
    return [...active.map((m) => word[m]!), keyLabel].join('+');
  }

  Map<String, Object> toJson() => {'key': key, 'mods': [for (final m in mods) m.name]};

  static ShortcutBinding? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['key'];
    final mods = j['mods'];
    if (key is! String || mods is! List) return null;
    final parsed = {
      for (final m in mods)
        for (final v in ShortcutMod.values)
          if (v.name == m) v,
    };
    final b = ShortcutBinding(key, parsed);
    return b.isValid ? b : null;
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutBinding &&
      other.key == key &&
      other.mods.length == mods.length &&
      other.mods.containsAll(mods);

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(mods));
}

/// Plan §3.6 defaults.
Map<ShortcutAction, ShortcutBinding> defaultShortcuts({required bool mac}) {
  const ca = {ShortcutMod.ctrl, ShortcutMod.alt};
  return {
    ShortcutAction.playPause: const ShortcutBinding('space', ca),
    ShortcutAction.slower: const ShortcutBinding('down', ca),
    ShortcutAction.faster: const ShortcutBinding('up', ca),
    ShortcutAction.restart: const ShortcutBinding('r', ca),
    ShortcutAction.backToStudio: mac
        ? const ShortcutBinding('e', {ShortcutMod.meta, ShortcutMod.shift})
        : const ShortcutBinding('e', {ShortcutMod.ctrl, ShortcutMod.shift}),
  };
}

String encodeShortcuts(Map<ShortcutAction, ShortcutBinding> m) =>
    jsonEncode({for (final e in m.entries) e.key.name: e.value.toJson()});

/// Saved bindings layered over the defaults; anything unreadable falls back.
Map<ShortcutAction, ShortcutBinding> decodeShortcuts(String? raw, {required bool mac}) {
  final out = defaultShortcuts(mac: mac);
  if (raw == null) return out;
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return out;
    for (final a in ShortcutAction.values) {
      final b = ShortcutBinding.fromJson(j[a.name]);
      if (b != null) out[a] = b;
    }
  } on FormatException {
    // Corrupt preferences: keep defaults.
  }
  return out;
}
