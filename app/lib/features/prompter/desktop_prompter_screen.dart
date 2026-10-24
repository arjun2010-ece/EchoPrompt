import '../../services/platform.dart';
import 'dart:async';
import 'dart:io' show Platform, exit;
import 'dart:math' as math;
import 'dart:ui' show AppExitType;

import 'package:echoprompter_window/echoprompter_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/labels.dart';
import '../../core/settings/prompt_settings.dart';
import '../../core/shortcuts/shortcut_binding.dart';
import '../../services/providers.dart';
import '../../services/window/prompter_window.dart';
import '../../ui/position_picker.dart';
import '../../ui/prompt_text_controls.dart';
import 'notch_clipper.dart';
import 'prompt_surface.dart';
import 'prompter_controller.dart';

const _accent = Color(0xFF0A84FF);
const _baseSpeed = 24.0;
const _speedSteps = [0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0];
const _firstStartToastKey = 'EchoPrompter.firstStartToast.v1';

bool get _mac => isMacOS;

/// R1: the single native window reconfigured as a floating, top-most,
/// capture-hidden prompter. Layouts mirror the Swift proof of concept:
/// `full` (header + control bar), `compact` (hover bar) and `notch`.
/// Placement changes only switch layout parameters, so the reading position
/// is kept.
///
/// You can always leave: the ✕ button, Esc and ⌘W/Ctrl+W go back to Script
/// Studio; the ⋯ menu quits; and while the prompter is open the menu-bar /
/// notification-area icon and the global shortcuts do the same from any app.
class DesktopPrompterScreen extends ConsumerStatefulWidget {
  const DesktopPrompterScreen({super.key});
  @override
  ConsumerState<DesktopPrompterScreen> createState() => _DesktopPrompterScreenState();
}

class _DesktopPrompterScreenState extends ConsumerState<DesktopPrompterScreen> {
  late final PrompterWindow _window = PrompterWindow(ref.read(prefsProvider));
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _hasNotch = false;
  bool _captureHidingSupported = true;
  bool _hoverBar = false;
  int _hoverToken = 0;
  int _openMenus = 0;

  String? _lastTray;

  String? _banner;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(EchoPrompterWindow.frameChanges.listen(_onFrame))
      ..add(EchoPrompterWindow.trayActions.listen(_onCommand))
      ..add(EchoPrompterWindow.hotkeys.listen(_onCommand));
    EchoPrompterWindow.hasHardwareNotch.then((v) {
      if (!mounted) return;
      setState(() => _hasNotch = v);
      _syncTray();
    }, onError: (_) {});
    EchoPrompterWindow.supportsCaptureHiding.then(
      (v) => mounted ? setState(() => _captureHidingSupported = v) : null,
      onError: (_) {},
    );
    _window.enter(ref.read(settingsProvider));
    _begin();
    _registerHotkeys();
    _showOpeningBanner();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTray());
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _bannerTimer?.cancel();
    EchoPrompterWindow.unregisterHotkeys();
    EchoPrompterWindow.setTrayMenu(null);
    _window.exit();
    super.dispose();
  }

  void _onFrame(WindowFrameEvent e) {
    final s = ref.read(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    _window.onFrame(e, s);
    if (e.notchHeight != null) {
      set((v) => v.copyWith(notchSize: Size(v.notchSize.width, e.notchHeight!)));
    } else if (s.placement == PromptPlacement.corner) {
      set(
        (v) => v.copyWith(
          corner: e.snappedCorner == null ? null : PromptCorner.values.byName(e.snappedCorner!.name),
          cornerSize: e.frame.size,
        ),
      );
    }
  }

  Future<void> _begin() async {
    final studio = ref.read(studioProvider);
    final mode = ref.read(settingsProvider).mode;
    final c = ref.read(prompterProvider.notifier);
    await c.begin(
      sessionId: studio.sessionId,
      script: studio.script,
      mode: mode,
      audioPath: ref.read(audioPathProvider),
    );
    // Like the Swift app, Voice mode starts listening as soon as it opens.
    if (mode == PromptControlMode.voice && mounted) await c.play();
  }

  // --- banner ------------------------------------------------------------------

  void _showBanner(String text, {Duration duration = const Duration(seconds: 3)}) {
    _bannerTimer?.cancel();
    setState(() => _banner = text);
    _bannerTimer = Timer(duration, () {
      if (mounted) setState(() => _banner = null);
    });
  }

  String _shortcut(ShortcutAction a) =>
      ref.read(shortcutsProvider)[a]!.label(mac: _mac);

  void _showOpeningBanner() {
    final prefs = ref.read(prefsProvider);
    final hidden = ref.read(settingsProvider).hideFromCapture && _captureHidingSupported;
    final first = !(prefs.getBool(_firstStartToastKey) ?? false);
    if (first) {
      prefs.setBool(_firstStartToastKey, true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showBanner(
          '${hidden ? 'Hidden from screen sharing' : 'Visible in screen sharing'}  ·  '
          'Esc: back to script  ·  ${_shortcut(ShortcutAction.playPause)}: play from any app',
          duration: const Duration(seconds: 6),
        );
      });
    } else if (hidden) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showBanner('Hidden from screen sharing');
      });
    }
  }

  // --- hover bar -------------------------------------------------------------

  void _hover(bool inside) {
    final token = ++_hoverToken;
    if (inside) {
      setState(() => _hoverBar = true);
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && token == _hoverToken && _openMenus == 0) {
        setState(() => _hoverBar = false);
      }
    });
  }

  void _menuChanged(bool open) {
    _openMenus = math.max(0, _openMenus + (open ? 1 : -1));
    if (!open) _hover(false);
  }

  // --- actions ---------------------------------------------------------------

  PromptControlMode get _mode => ref.read(settingsProvider).mode;

  void _primary() {
    final pr = ref.read(prompterProvider);
    if (_mode == PromptControlMode.recordedAudio && pr.preparing) return;
    ref.read(prompterProvider.notifier).togglePlay();
  }

  void _restart() async {
    final c = ref.read(prompterProvider.notifier);
    final wasVoice = _mode == PromptControlMode.voice;
    await c.restart();
    if (wasVoice) await c.play(); // a Voice restart is a fresh read
  }

  void _changeSpeed(bool forward) {
    if (_mode != PromptControlMode.normal) return;
    final set = ref.read(settingsProvider.notifier).update;
    final rate = ref.read(settingsProvider).speed / _baseSpeed;
    final next = forward
        ? _speedSteps.firstWhere((x) => x > rate + 0.01, orElse: () => _speedSteps.last)
        : _speedSteps.lastWhere((x) => x < rate - 0.01, orElse: () => _speedSteps.first);
    set((v) => v.copyWith(speed: next * _baseSpeed));
  }

  void _changeTextSize(double delta) =>
      ref.read(settingsProvider.notifier).update((v) => v.copyWith(fontSize: v.fontSize + delta));

  /// Where the presenter had reached, for the Studio caret.
  int _readingWord() {
    if (_mode == PromptControlMode.normal) return ref.read(readingWordProvider);
    final p = ref.read(prompterProvider).progress;
    return math.max(0, math.max(p.confirmedWordIndex, p.predictedWordIndex ?? 0));
  }

  /// Ends the session and returns to Script Studio. [atReadingPosition] puts
  /// the editor caret on the word that was being read ("Edit script").
  Future<void> _backToStudio({bool atReadingPosition = false}) async {
    final word = atReadingPosition ? _readingWord() : null;
    ref.read(prompterProvider.notifier).pause();
    // Restore the Studio window frame (kept invisible) before swapping
    // screens, then reveal it once Studio has painted, so neither the old
    // content at the new size nor the resize is ever seen.
    await _window.exit();
    if (!mounted) return;
    ref.read(studioProvider.notifier).stopPresenting(wordIndex: word);
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    EchoPrompterWindow.revealStudio();
  }

  void _quit() {
    ref.read(prompterProvider.notifier).pause();
    // Engine shutdown can take a few seconds on Windows; hide the window and
    // tray icon first so quitting looks instant.
    unawaited(EchoPrompterWindow.setPrompterVisible(false));
    EchoPrompterWindow.unregisterHotkeys();
    EchoPrompterWindow.setTrayMenu(null);
    // Windows keeps the busy cursor for seconds while the engine shuts down
    // gracefully, so end the process once the window is gone.
    if (Platform.isWindows) {
      final saved = ref.read(studioProvider.notifier).flush();
      Future<void>.delayed(const Duration(milliseconds: 100))
          .then((_) => saved)
          .whenComplete(() => exit(0));
      return;
    }
    ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  void _setPlacement(PromptPlacement p) =>
      ref.read(settingsProvider.notifier).update((c) => c.copyWith(placement: p));

  /// Handles a tray-menu pick or a global shortcut. Both use the same ids.
  void _onCommand(String id) {
    if (!mounted) return;
    switch (id) {
      case 'playPause':
        _primary();
      case 'slower':
        _changeSpeed(false);
      case 'faster':
        _changeSpeed(true);
      case 'restart':
        _restart();
      case 'backToStudio':
        _backToStudio(atReadingPosition: true);
      case 'quit':
        _quit();
      case 'place:notch':
        _setPlacement(PromptPlacement.notch);
      case 'place:corner':
        _setPlacement(PromptPlacement.corner);
      case 'place:floating':
        _setPlacement(PromptPlacement.floating);
    }
  }

  // --- tray + global shortcuts -------------------------------------------------

  Future<void> _registerHotkeys() async {
    final bindings = ref.read(shortcutsProvider);
    await EchoPrompterWindow.registerHotkeys([
      for (final e in bindings.entries)
        HotkeyBinding(e.key.name, e.value.key, {for (final m in e.value.mods) m.name}),
    ]);
  }

  Future<void> _syncTray() async {
    if (!mounted) return;
    final s = ref.read(settingsProvider);
    final pr = ref.read(prompterProvider);
    final normal = s.mode == PromptControlMode.normal;
    final items = <TrayItem>[
      TrayItem('playPause', _primaryInfo(s, pr).title, enabled: !(s.mode == PromptControlMode.recordedAudio && pr.preparing)),
      TrayItem('slower', 'Slower', enabled: normal),
      TrayItem('faster', 'Faster', enabled: normal),
      const TrayItem('restart', 'Restart from the beginning'),
      const TrayItem.separator(),
      TrayItem('place:notch', 'Position: ${PromptPlacement.notch.label(hasNotch: _hasNotch)}', checked: s.placement == PromptPlacement.notch),
      TrayItem('place:corner', 'Position: Corner', checked: s.placement == PromptPlacement.corner),
      TrayItem('place:floating', 'Position: Floating', checked: s.placement == PromptPlacement.floating),
      const TrayItem.separator(),
      const TrayItem('backToStudio', 'Back to Script Studio'),
      const TrayItem('quit', 'Quit EchoPrompter'),
    ];
    final signature = items.map((i) => '${i.id}|${i.title}|${i.enabled}|${i.checked}').join(';');
    if (signature == _lastTray) return;
    _lastTray = signature;
    await EchoPrompterWindow.setTrayMenu(items);
  }

  // --- layout choice ---------------------------------------------------------

  PromptLayoutStyle _style(PromptSettings s, Size size) => switch (s.placement) {
    PromptPlacement.notch => PromptLayoutStyle.notch,
    PromptPlacement.corner => PromptLayoutStyle.compact,
    PromptPlacement.floating => size.width < 560 || size.height < 260 ? PromptLayoutStyle.compact : PromptLayoutStyle.full,
  };

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider, (prev, next) {
      if (prev == null) return;
      if (prev.placement != next.placement ||
          prev.corner != next.corner ||
          prev.hideFromCapture != next.hideFromCapture ||
          prev.notchSize.width != next.notchSize.width) {
        _window.update(next);
      }
      if (prev.mode != next.mode) _begin();
      _syncTray();
    });
    ref.listen(prompterProvider.select((p) => (p.playing, p.preparing)), (_, _) => _syncTray());
    ref.listen(shortcutsProvider, (_, _) => _registerHotkeys());
    final s = ref.watch(settingsProvider);
    final mod = _mac ? (meta: true, control: false) : (meta: false, control: true);

    // The window is transparent; Material is only needed for InkWell/menus.
    return Material(
      type: MaterialType.transparency,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _backToStudio,
          SingleActivator(LogicalKeyboardKey.keyW, meta: mod.meta, control: mod.control): _backToStudio,
          const SingleActivator(LogicalKeyboardKey.space): _primary,
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _changeSpeed(true),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _changeSpeed(false),
          SingleActivator(LogicalKeyboardKey.equal, meta: mod.meta, control: mod.control): () => _changeTextSize(4),
          SingleActivator(LogicalKeyboardKey.minus, meta: mod.meta, control: mod.control): () => _changeTextSize(-4),
          if (!_mac) const SingleActivator(LogicalKeyboardKey.keyQ, control: true): _quit,
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, c) {
              final style = _style(s, c.biggest);
              return MouseRegion(
                onEnter: (_) => _hover(true),
                onExit: (_) => _hover(false),
                child: Stack(
                  children: [
                    switch (style) {
                      PromptLayoutStyle.full => _fullLayout(s),
                      PromptLayoutStyle.compact => _compactLayout(s),
                      PromptLayoutStyle.notch => _notchLayout(s),
                    },
                    if (s.placement != PromptPlacement.notch) ..._resizeHandles(),
                    _statusBadges(s, style),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // --- badges + banner -------------------------------------------------------

  /// A short-lived banner (opening hint) plus the badge that must not go
  /// unnoticed: the prompter is visible to viewers.
  Widget _statusBadges(PromptSettings s, PromptLayoutStyle style) {
    final visibleToViewers = !s.hideFromCapture || !_captureHidingSupported;
    Widget chip(IconData icon, String text, Color color) => DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600))),
        ]),
      ),
    );

    final top = style == PromptLayoutStyle.full ? 52.0 : (style == PromptLayoutStyle.notch ? 40.0 : 8.0);
    final banner = _banner;
    return Positioned(
      left: 8,
      right: 8,
      top: top,
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (visibleToViewers)
                chip(
                  Icons.visibility,
                  _captureHidingSupported ? 'Visible to viewers' : 'Windows can’t hide this from capture',
                  Colors.orange,
                ),
            ]),
            if (banner != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Center(child: chip(Icons.shield_outlined, banner, Colors.white)),
              ),
          ],
        ),
      ),
    );
  }

  // --- layouts ---------------------------------------------------------------

  Widget _surface(PromptLayoutStyle style) => PromptSurface(
    style: style,
    onDragStart: EchoPrompterWindow.gestureBegin,
    onDragUpdate: EchoPrompterWindow.dragUpdate,
    onDragEnd: EchoPrompterWindow.gestureEnd,
    coveredByDesktopChrome: style == PromptLayoutStyle.full,
  );

  Widget _frame(Widget child) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: child,
    ),
  );

  Widget _fullLayout(PromptSettings s) => _frame(
    Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: promptBackground.withValues(alpha: s.opacity))),
        Positioned.fill(child: _surface(PromptLayoutStyle.full)),
        Column(children: [_fullHeader(s), const Spacer(), _fullControlBar(s)]),
      ],
    ),
  );

  Widget _compactLayout(PromptSettings s) => _frame(
    Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: promptBackground.withValues(alpha: s.opacity))),
        Positioned.fill(child: _surface(PromptLayoutStyle.compact)),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _hoverBar ? 1 : 0,
              child: IgnorePointer(ignoring: !_hoverBar, child: _hoverBarWidget()),
            ),
          ),
        ),
        _attentionDot(),
      ],
    ),
  );

  Widget _notchLayout(PromptSettings s) {
    // The strip beside the hardware notch stays solid black so it reads as part
    // of the notch; the body below it follows the background-opacity setting.
    final inset = _hasNotch ? 34.0 : 0.0;
    return ClipPath(
      clipper: const NotchClipper(),
      child: Column(
        children: [
          if (inset > 0) SizedBox(height: inset, width: double.infinity, child: const ColoredBox(color: promptBackground)),
          Expanded(
            child: ColoredBox(
              color: promptBackground.withValues(alpha: s.opacity),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NotchClipper.flare),
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(child: _surface(PromptLayoutStyle.notch)),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 150),
                                opacity: _hoverBar ? 1 : 0,
                                child: IgnorePointer(ignoring: !_hoverBar, child: _hoverBarWidget()),
                              ),
                            ),
                          ),
                          _attentionDot(),
                        ],
                      ),
                    ),
                    _notchResizeHandle(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notchResizeHandle() => MouseRegion(
    cursor: SystemMouseCursors.resizeUpDown,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => EchoPrompterWindow.gestureBegin(),
      onPanUpdate: (_) => EchoPrompterWindow.resizeUpdate('b'),
      onPanEnd: (_) => EchoPrompterWindow.gestureEnd(),
      child: SizedBox(
        height: 12,
        child: Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)),
          ),
        ),
      ),
    ),
  );

  /// Invisible edge/corner grips (the window is borderless).
  List<Widget> _resizeHandles() {
    Widget grip({
      double? l,
      double? r,
      double? t,
      double? b,
      double? w,
      double? h,
      required String edge,
      required MouseCursor cursor,
    }) => Positioned(
      left: l,
      right: r,
      top: t,
      bottom: b,
      width: w,
      height: h,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => EchoPrompterWindow.gestureBegin(),
          onPanUpdate: (_) => EchoPrompterWindow.resizeUpdate(edge),
          onPanEnd: (_) => EchoPrompterWindow.gestureEnd(),
        ),
      ),
    );
    return [
      grip(l: 14, r: 14, b: 0, h: 8, edge: 'b', cursor: SystemMouseCursors.resizeUpDown),
      grip(r: 0, t: 40, b: 14, w: 8, edge: 'r', cursor: SystemMouseCursors.resizeLeftRight),
      grip(l: 0, t: 40, b: 14, w: 8, edge: 'l', cursor: SystemMouseCursors.resizeLeftRight),
      grip(r: 0, b: 0, w: 16, h: 16, edge: 'br', cursor: SystemMouseCursors.resizeDownRight),
      grip(l: 0, b: 0, w: 16, h: 16, edge: 'bl', cursor: SystemMouseCursors.resizeDownLeft),
    ];
  }

  // --- state-derived labels (mirrors the Swift app) ---------------------------

  String _rateLabel(PromptSettings s) => '${(s.speed / _baseSpeed).toStringAsFixed(2)}×';

  ({String title, String detail, IconData icon, Color? tint}) _primaryInfo(PromptSettings s, PrompterState pr) {
    switch (s.mode) {
      case PromptControlMode.voice:
        final listening = pr.playing;
        return (
          title: listening ? 'Listening' : 'Start voice',
          detail: listening ? 'waiting for speech' : 'tap to start',
          icon: listening ? Icons.mic : Icons.mic_off,
          tint: listening ? const Color(0xFF299E52) : const Color(0xFFC73833),
        );
      case PromptControlMode.recordedAudio:
        return (
          title: pr.preparing ? 'Preparing' : (pr.playing ? 'Pause' : 'Play'),
          detail: pr.preparing ? 'syncing words' : 'recorded audio',
          icon: pr.playing ? Icons.pause : Icons.play_arrow,
          tint: null,
        );
      case PromptControlMode.normal:
        return (
          title: pr.playing ? 'Pause' : 'Play',
          detail: _rateLabel(s),
          icon: pr.playing ? Icons.pause : Icons.play_arrow,
          tint: null,
        );
    }
  }

  bool _needsAttention(PromptSettings s, PrompterState pr) =>
      (s.mode == PromptControlMode.voice && !pr.playing) ||
      (s.mode == PromptControlMode.recordedAudio &&
          (pr.preparing || pr.status.isEmpty || !pr.status.startsWith('Ready') && !pr.playing && !pr.finished));

  String _footer(PromptSettings s, PrompterState pr) => switch (s.mode) {
    PromptControlMode.voice =>
      pr.playing
          ? 'Listening — start reading your script'
          : (pr.status.isEmpty || pr.status == 'Listening'
                ? 'Microphone off  •  Press Space or Start voice to resume listening'
                : 'Microphone off  •  ${pr.status}'),
    PromptControlMode.recordedAudio =>
      '${pr.status.isEmpty ? 'Choose an audio file in Script Studio' : pr.status}  •  Esc: back to script',
    PromptControlMode.normal => 'Space: play or pause   •   ↑ ↓: speed (${_rateLabel(s)})   •   Esc: back to script',
  };

  String _compactStatus(PromptSettings s, PrompterState pr) => switch (s.mode) {
    PromptControlMode.voice => _footer(s, pr).split('  •  ').first,
    PromptControlMode.recordedAudio => pr.status,
    PromptControlMode.normal => '${pr.playing ? 'Scrolling' : 'Paused'}  •  ${_rateLabel(s)}',
  };

  String _headerState(PromptSettings s, PrompterState pr) => switch (s.mode) {
    PromptControlMode.voice => pr.playing ? 'LISTENING' : 'MICROPHONE OFF',
    PromptControlMode.recordedAudio => (pr.status.isEmpty ? 'NO AUDIO' : pr.status).toUpperCase(),
    PromptControlMode.normal => pr.playing ? 'SCROLLING' : 'PAUSED',
  };

  // --- full layout pieces ----------------------------------------------------

  Widget _fullHeader(PromptSettings s) {
    final pr = ref.watch(prompterProvider);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => EchoPrompterWindow.gestureBegin(),
      onPanUpdate: (_) => EchoPrompterWindow.dragUpdate(),
      onPanEnd: (_) => EchoPrompterWindow.gestureEnd(),
      child: Container(
        color: Colors.black.withValues(alpha: 0.96),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: DefaultTextStyle(
          style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 12, fontWeight: FontWeight.w700),
          child: Row(
            children: [
              _HeaderButton(icon: Icons.close, label: 'Close', tooltip: 'Close the prompter and return to Script Studio (Esc)', onTap: _backToStudio),
              const SizedBox(width: 4),
              _HeaderButton(
                icon: Icons.edit,
                label: 'Edit script',
                tooltip: 'Return to Script Studio at the word you were reading',
                onTap: () => _backToStudio(atReadingPosition: true),
              ),
              const Spacer(),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [Text(s.mode.headerName), const SizedBox(height: 2), Text(_headerState(s, pr))],
              ),
              const Spacer(),
              _positionMenu(s, labelled: true),
              const SizedBox(width: 4),
              _moreMenu(labelled: false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fullControlBar(PromptSettings s) {
    final pr = ref.watch(prompterProvider);
    final info = _primaryInfo(s, pr);
    final normal = s.mode == PromptControlMode.normal;
    final paced = s.mode == PromptControlMode.voice ? 'voice paced' : 'audio paced';
    final attention = _needsAttention(s, pr);
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.18))),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.7), blurRadius: 14, offset: const Offset(0, -5))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: math.max(0, MediaQuery.sizeOf(context).width - 36)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ControlButton(title: 'Restart', detail: 'from the top', icon: Icons.replay, onTap: _restart),
                  const SizedBox(width: 12),
                  _ControlButton(
                    title: 'Slower',
                    detail: normal ? '− speed' : paced,
                    icon: Icons.keyboard_double_arrow_left,
                    enabled: normal,
                    onTap: () => _changeSpeed(false),
                  ),
                  const SizedBox(width: 12),
                  _ControlButton(
                    title: info.title,
                    detail: info.detail,
                    icon: info.icon,
                    prominent: true,
                    tint: info.tint,
                    enabled: !(s.mode == PromptControlMode.recordedAudio && pr.preparing),
                    onTap: _primary,
                  ),
                  const SizedBox(width: 12),
                  _ControlButton(
                    title: 'Faster',
                    detail: normal ? '+ speed' : paced,
                    icon: Icons.keyboard_double_arrow_right,
                    enabled: normal,
                    onTap: () => _changeSpeed(true),
                  ),
                  const SizedBox(width: 12),
                  _textMenu(
                    builder: (controller) => _ControlButton(
                      title: 'Text',
                      detail: 'Aa',
                      icon: Icons.text_fields,
                      onTap: () => controller.isOpen ? controller.close() : controller.open(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _footer(s, pr),
            style: TextStyle(fontSize: 12, color: attention ? Colors.orange : Colors.white.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  /// "Aa" popover: the same size / spacing / opacity controls as Studio.
  Widget _textMenu({required Widget Function(MenuController) builder}) => MenuAnchor(
    onOpen: () => _menuChanged(true),
    onClose: () => _menuChanged(false),
    menuChildren: const [
      Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(width: 320, child: PromptTextControls()),
      ),
    ],
    builder: (context, controller, _) => builder(controller),
  );

  // --- hover bar (compact + notch) --------------------------------------------

  Widget _hoverBarWidget() {
    final s = ref.watch(settingsProvider);
    final pr = ref.watch(prompterProvider);
    final info = _primaryInfo(s, pr);
    final normal = s.mode == PromptControlMode.normal;
    final attention = _needsAttention(s, pr);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.88), borderRadius: BorderRadius.circular(10)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Shrinks rather than overflows in the narrowest corner window.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HoverIconButton(
                  icon: info.icon,
                  label: info.title,
                  prominent: true,
                  tint: info.tint,
                  enabled: !(s.mode == PromptControlMode.recordedAudio && pr.preparing),
                  onTap: _primary,
                ),
                const SizedBox(width: 4),
                _HoverIconButton(icon: Icons.keyboard_double_arrow_left, label: 'Slower', enabled: normal, onTap: () => _changeSpeed(false)),
                const SizedBox(width: 4),
                _HoverIconButton(icon: Icons.keyboard_double_arrow_right, label: 'Faster', enabled: normal, onTap: () => _changeSpeed(true)),
                const SizedBox(width: 4),
                _HoverIconButton(icon: Icons.replay, label: 'Restart from the beginning', onTap: _restart),
                const SizedBox(width: 4),
                _textMenu(
                  builder: (controller) => _HoverIconButton(
                    icon: Icons.text_fields,
                    label: 'Text appearance',
                    onTap: () => controller.isOpen ? controller.close() : controller.open(),
                  ),
                ),
                const SizedBox(width: 4),
                _positionMenu(s, labelled: false),
                const SizedBox(width: 4),
                _moreMenu(labelled: false),
                const SizedBox(width: 4),
                _HoverIconButton(icon: Icons.close, label: 'Close prompter and return to Script Studio', onTap: _backToStudio),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _compactStatus(s, pr),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: attention ? Colors.orange : Colors.white.withValues(alpha: 0.75)),
          ),
        ],
      ),
    );
  }

  Widget _attentionDot() {
    final s = ref.watch(settingsProvider);
    final pr = ref.watch(prompterProvider);
    if (!_needsAttention(s, pr)) return const SizedBox.shrink();
    return const Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: EdgeInsets.all(10),
        child: IgnorePointer(
          child: SizedBox(
            width: 6,
            height: 6,
            child: DecoratedBox(decoration: BoxDecoration(color: Colors.orange, shape: BoxShape.circle)),
          ),
        ),
      ),
    );
  }

  // --- menus -----------------------------------------------------------------

  /// A menu inside the same window, so it is covered by capture hiding too.
  /// Labelled "Position" in the header; an icon in the compact hover bar.
  Widget _positionMenu(PromptSettings s, {required bool labelled}) {
    final set = ref.read(settingsProvider.notifier).update;
    Widget check(String title, bool on, VoidCallback onTap) => MenuItemButton(
      leadingIcon: SizedBox(width: 18, child: on ? const Icon(Icons.check, size: 16) : null),
      onPressed: onTap,
      child: Text(title),
    );
    return MenuAnchor(
      onOpen: () => _menuChanged(true),
      onClose: () => _menuChanged(false),
      menuChildren: [
        check(
          '${PromptPlacement.notch.label(hasNotch: _hasNotch)}${_hasNotch ? '' : ' (under the camera)'}',
          s.placement == PromptPlacement.notch,
          () => _setPlacement(PromptPlacement.notch),
        ),
        SubmenuButton(
          menuChildren: [
            for (final corner in PromptCorner.values)
              check(
                corner.label,
                s.placement == PromptPlacement.corner && s.corner == corner,
                () => set((c) => c.copyWith(placement: PromptPlacement.corner, corner: corner)),
              ),
          ],
          child: const Text('Corner'),
        ),
        check('Floating', s.placement == PromptPlacement.floating, () => _setPlacement(PromptPlacement.floating)),
        if (s.placement == PromptPlacement.notch) ...[
          const Divider(height: 1),
          SubmenuButton(
            menuChildren: [
              for (final (name, w) in notchWidths)
                check(name, s.notchSize.width == w, () => set((c) => c.copyWith(notchSize: Size(w, c.notchSize.height)))),
            ],
            child: const Text('Width'),
          ),
        ],
      ],
      builder: (context, controller, _) => labelled
          ? _HeaderButton(
              icon: Icons.open_with,
              label: 'Position',
              tooltip: 'Where the prompter sits',
              trailing: Icons.arrow_drop_down,
              onTap: () => controller.isOpen ? controller.close() : controller.open(),
            )
          : _HoverIconButton(
              icon: Icons.open_with,
              label: 'Prompter position',
              onTap: () => controller.isOpen ? controller.close() : controller.open(),
            ),
    );
  }

  /// "⋯": Edit script and Quit, so leaving the app never needs a detour.
  Widget _moreMenu({required bool labelled}) => MenuAnchor(
    onOpen: () => _menuChanged(true),
    onClose: () => _menuChanged(false),
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(Icons.edit, size: 16),
        onPressed: () => _backToStudio(atReadingPosition: true),
        child: const Text('Edit script'),
      ),
      const Divider(height: 1),
      MenuItemButton(
        leadingIcon: const Icon(Icons.power_settings_new, size: 16),
        onPressed: _quit,
        child: const Text('Quit EchoPrompter'),
      ),
    ],
    builder: (context, controller, _) => _HoverIconButton(
      icon: Icons.more_horiz,
      label: 'More: edit script, quit',
      onTap: () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

/// A labelled button for the full layout's header.
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.label, required this.tooltip, required this.onTap, this.trailing});
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.9)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if (trailing != null) Icon(trailing, size: 18, color: Colors.white.withValues(alpha: 0.9)),
          ]),
        ),
      ),
    ),
  );
}

class _HoverIconButton extends StatelessWidget {
  const _HoverIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.prominent = false,
    this.tint,
    this.enabled = true,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool prominent;
  final Color? tint;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onTap : null,
            child: Container(
              width: 28,
              height: 24,
              decoration: BoxDecoration(
                color: prominent ? (tint ?? _accent) : Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.title,
    required this.detail,
    required this.icon,
    required this.onTap,
    this.prominent = false,
    this.tint,
    this.enabled = true,
  });
  final String title;
  final String detail;
  final IconData icon;
  final VoidCallback onTap;
  final bool prominent;
  final Color? tint;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : 0.42,
    child: MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: prominent ? (tint ?? _accent) : const Color(0xFF38383D),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 9),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                  Text(
                    detail,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
