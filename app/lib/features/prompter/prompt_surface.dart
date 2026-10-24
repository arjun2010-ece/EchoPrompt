import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/progress/reading_progress.dart';
import '../../core/script/text.dart';
import '../../core/settings/prompt_settings.dart';
import '../../services/platform.dart';
import '../../services/providers.dart';
import 'prompter_controller.dart';
import 'word_layout.dart';

enum PromptLayoutStyle { full, compact, notch }

/// The prompter is always light text on black, like a hardware teleprompter.
/// (It does not follow the app's light/dark appearance.)
const promptBackground = Colors.black;
const promptText = Colors.white;

/// The scrolling script text, shared by every host. Port of the Swift
/// `scriptArea`: centered words, live word in orange, completed words
/// softened, text starting ~42% down so the reading line rests mid-window.
///
/// Every mode moves through one `offset`: Normal adds to it at `speed`; Voice
/// and Audio ease it toward the spoken word (forward only).
class PromptSurface extends ConsumerStatefulWidget {
  const PromptSurface({
    super.key,
    this.style = PromptLayoutStyle.full,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onWordTap,
    this.onTapIntercept,
    this.previewWordIndex,
    this.scriptOverride,
    this.coveredByDesktopChrome = false,
  });

  final PromptLayoutStyle style;

  /// Desktop: the window is dragged by its text area (it has no title bar).
  final VoidCallback? onDragStart;
  final VoidCallback? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// Mobile: tap a word to jump there.
  final bool? onWordTap;

  /// Mobile: called first on a tap; returning true consumes it (no word jump).
  final bool Function()? onTapIntercept;

  /// Studio preview: a static rendering with this word on the reading line.
  /// It ignores the live session (no scrolling, highlighting or wakelock).
  final int? previewWordIndex;

  /// Replaces the script from [studioProvider]; lets a preview debounce typing.
  final String? scriptOverride;

  /// Desktop full layout: a header and control bar overlay the top and bottom
  /// edges, so the reading line must sit between them.
  final bool coveredByDesktopChrome;

  bool get isPreview => previewWordIndex != null;

  /// Approximate heights of the desktop full layout's header and control bar.
  static const _fullHeaderInset = 52.0;
  static const _fullControlBarInset = 110.0;

  /// Words Voice mode scrolls ahead of the highlight, about the recognizer's lag.
  static const _voiceLeadWords = 2;

  /// Voice mode starts scrolling to the next paragraph this many words before the break.
  static const _paragraphLookWords = 3;

  @override
  ConsumerState<PromptSurface> createState() => _PromptSurfaceState();
}

class _PromptSurfaceState extends ConsumerState<PromptSurface> with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _offset = 0;
  double _followTarget = 0;
  int _lastConfirmed = -1;
  String _rawScript = '';
  String _tidyScript = '';
  WordLayout? _layout;
  Object? _layoutKey;
  int _resetToken = -1;
  bool _wakelocked = false;
  double _anchorY = 0;
  double _topPad = 0;
  double _lastReport = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  /// Starts the frame ticker if it went to sleep; a new run's clock starts at zero.
  void _wake() {
    if (_ticker.isActive || widget.isPreview) return;
    _last = Duration.zero;
    _ticker.start();
  }

  /// Mobile: nothing is moving, so stop asking for frames. A running ticker redraws the
  /// whole prompter every frame (most of a CPU core on the emulator), which starves the
  /// speech recogniser. The reference's text view only draws when something changes.
  void _sleep() {
    if (isMobile) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scroll.dispose();
    if (_wakelocked) WakelockPlus.disable();
    super.dispose();
  }

  void _reset() {
    _offset = 0;
    _followTarget = 0;
    _lastConfirmed = -1;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (!widget.isPreview) ref.read(readingWordProvider.notifier).set(0);
  }

  /// Tells Studio where the presenter is, a few times a second at most.
  void _reportReadingWord(double now) {
    final layout = _layout;
    if (layout == null || now - _lastReport < 0.25) return;
    _lastReport = now;
    final y = _offset + _anchorY - _topPad;
    ref.read(readingWordProvider.notifier).set(layout.nearestWord(Offset(layout.painter.width / 2, y)));
  }

  void _tick(Duration now) {
    final dt = math.min(0.1, (now - _last).inMicroseconds / 1e6);
    _last = now;
    if (widget.isPreview) return _sleep();
    if (!_scroll.hasClients) return;
    final settings = ref.read(settingsProvider);
    final pr = ref.read(prompterProvider);
    final max = _scroll.position.maxScrollExtent;
    if (settings.mode == PromptControlMode.normal) {
      if (!pr.playing) return _sleep();
      _offset += settings.speed * dt;
      if (_offset >= max) {
        _offset = max;
        ref.read(prompterProvider.notifier).markFinished();
      }
    } else if ((_followTarget - _offset).abs() > 0.05) {
      // Frame-rate independent exponential easing toward the spoken word.
      final settle = settings.mode == PromptControlMode.voice ? 0.25 : 0.38;
      _offset += (_followTarget - _offset) * (1 - math.exp(-dt / settle));
    } else {
      return _sleep();
    }
    _scroll.jumpTo(_offset.clamp(0.0, max).toDouble());
    _reportReadingWord(now.inMicroseconds / 1e6);
  }

  void _syncWakelock(bool playing) {
    if (playing == _wakelocked) return;
    _wakelocked = playing;
    try {
      playing ? WakelockPlus.enable() : WakelockPlus.disable();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final studioScript = ref.watch(studioProvider.select((s) => s.script));
    final rawScript = widget.scriptOverride ?? studioScript;
    if (rawScript != _rawScript) {
      _rawScript = rawScript;
      _tidyScript = tidyBlankLines(rawScript);
    }
    final script = _tidyScript;
    final preview = widget.isPreview;
    final pr = preview ? const PrompterState() : ref.watch(prompterProvider);
    if (!preview) _syncWakelock(pr.playing);
    if (!preview && settings.mode == PromptControlMode.normal && pr.playing) _wake();
    if (!preview && pr.resetToken != _resetToken) {
      _resetToken = pr.resetToken;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reset());
    }

    final style = widget.style;
    final notch = style == PromptLayoutStyle.notch;
    const textColor = promptText;

    Widget body = LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      final hPad = style == PromptLayoutStyle.full ? 56.0 : (notch ? 16.0 : 20.0);
      // Small layouts keep at least ~2 lines visible.
      final fontSize = style == PromptLayoutStyle.full
          ? settings.fontSize
          : math.min(settings.fontSize, math.max(16.0, h / 3));
      // The full layout's header and control bar cover the top and bottom edges
      // (desktop), so its reading line sits in the clear band between them;
      // otherwise upcoming lines would hide under the bar.
      final clearTop = style == PromptLayoutStyle.full && widget.coveredByDesktopChrome ? PromptSurface._fullHeaderInset : 0.0;
      final clearBottom = style == PromptLayoutStyle.full && widget.coveredByDesktopChrome ? PromptSurface._fullControlBarInset : 0.0;
      final clearH = math.max(0.0, h - clearTop - clearBottom);
      final fullDesktop = clearTop > 0;
      final topPad = fullDesktop ? clearTop + clearH * 0.3 : h * (notch ? 0.35 : 0.42);
      final anchorY = fullDesktop ? clearTop + clearH * 0.4 : h * (notch ? 0.4 : 0.5);
      final bottomPad = notch ? h : (fullDesktop ? math.max(0.0, h - anchorY) : h * 0.42);
      _anchorY = anchorY;
      _topPad = topPad;
      final width = math.max(40.0, c.maxWidth - hPad * 2);
      final base = TextStyle(
        fontSize: fontSize,
        height: settings.lineSpacing,
        fontWeight: FontWeight.w500,
        color: textColor,
      );
      final key = (script, fontSize, settings.lineSpacing, width);
      if (_layoutKey != key) {
        _layoutKey = key;
        _layout = WordLayout(script, base, width, align: TextAlign.center);
      }
      final layout = _layout!;

      if (preview && layout.ranges.isNotEmpty) {
        final word = widget.previewWordIndex!.clamp(0, layout.ranges.length - 1);
        final target = math.max(0.0, topPad + layout.midY(word) - anchorY);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scroll.hasClients) return;
          _offset = target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
          _scroll.jumpTo(_offset);
        });
      }

      final idx = math.max(pr.progress.confirmedWordIndex, pr.progress.predictedWordIndex ?? -1);
      if (!preview && settings.mode != PromptControlMode.normal && idx >= 0 && idx < layout.ranges.length) {
        // Live recognition trails the voice by a couple of words, so Voice mode
        // scrolls to where the reader already is. With big text only a line or
        // two is visible, and waiting for the highlight would stall the reader.
        final lead = settings.mode == PromptControlMode.voice ? PromptSurface._voiceLeadWords : 0;
        var scrollWord = math.min(idx + lead, layout.ranges.length - 1);
        // Near the end of a paragraph, bring the next one up while the reader
        // is still finishing this one, instead of after the pause that follows.
        if (lead > 0) {
          final next = layout.paragraphStartWithin(idx, PromptSurface._paragraphLookWords);
          if (next != null) scrollWord = math.max(scrollWord, next);
        }
        // Never pull the prompt backward for a short-lived predictive cue, but do follow the
        // confirmed word when it moves back (the reader repeated a passage or tapped an earlier word).
        final target = math.max(0.0, topPad + layout.midY(scrollWord) - anchorY);
        final confirmed = pr.progress.confirmedWordIndex;
        _followTarget = confirmed < _lastConfirmed ? target : math.max(_followTarget, target);
        _lastConfirmed = confirmed;
        if ((_followTarget - _offset).abs() > 0.05) _wake();
      }

      Widget text = Text.rich(
        _spans(script, layout, base, pr.progress, textColor),
        textAlign: TextAlign.center,
        textWidthBasis: TextWidthBasis.parent,
      );
      if (settings.mirror) text = Transform.flip(flipX: true, child: text);
      // Rotation is for mobile glass rigs; desktop OSes rotate whole displays.
      if (settings.rotated && isMobile) text = RotatedBox(quarterTurns: 2, child: text);

      Widget scroller = SingleChildScrollView(
        controller: _scroll,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(hPad, topPad, hPad, bottomPad),
        child: SizedBox(width: double.infinity, child: text),
      );

      if (preview) return IgnorePointer(child: scroller);
      if (widget.onDragStart != null) {
        scroller = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => widget.onDragStart!(),
          onPanUpdate: (_) => widget.onDragUpdate?.call(),
          onPanEnd: (_) => widget.onDragEnd?.call(),
          onDoubleTap: () => ref.read(prompterProvider.notifier).togglePlay(),
          child: scroller,
        );
      } else if (widget.onWordTap == true) {
        scroller = GestureDetector(
          onTapUp: (d) {
            if (widget.onTapIntercept?.call() ?? false) return;
            final p = d.localPosition + Offset(-hPad, _offset - topPad);
            final i = layout.wordAt(p);
            if (i != null) ref.read(prompterProvider.notifier).seekTo(i);
          },
          onDoubleTap: () => ref.read(prompterProvider.notifier).togglePlay(),
          child: scroller,
        );
      }
      return scroller;
    });

    // Small layouts fade lines out at the top edge instead of cutting them off;
    // the full layout's header already covers that edge.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0, style == PromptLayoutStyle.full ? 0.0001 : 0.22, 1],
        colors: const [Color(0x00000000), Colors.black, Colors.black],
      ).createShader(r),
      child: ClipRect(child: body),
    );
  }

  TextSpan _spans(String script, WordLayout layout, TextStyle base, PromptReadingProgress progress, Color text) {
    final children = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < layout.ranges.length; i++) {
      final r = layout.ranges[i];
      if (r.start > cursor) children.add(TextSpan(text: script.substring(cursor, r.start)));
      final style = switch (progress.stateFor(i)) {
        WordState.completed => TextStyle(color: text.withValues(alpha: 0.46)),
        WordState.current => const TextStyle(
          color: Colors.orange,
          decoration: TextDecoration.underline,
          decorationColor: Colors.orange,
        ),
        WordState.predicted => TextStyle(
          color: Colors.orange.withValues(alpha: 0.65),
          decoration: TextDecoration.underline,
          decorationColor: Colors.orange.withValues(alpha: 0.55),
        ),
        WordState.upcoming => null,
      };
      children.add(TextSpan(text: script.substring(r.start, r.end), style: style));
      cursor = r.end;
    }
    if (cursor < script.length) children.add(TextSpan(text: script.substring(cursor)));
    return TextSpan(style: base, children: children);
  }
}
