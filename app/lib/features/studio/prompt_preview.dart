import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/prompt_settings.dart';
import '../../services/providers.dart';
import '../prompter/notch_clipper.dart';
import '../prompter/prompt_surface.dart';

/// Size of the real prompter window for each position, in logical points.
Size promptWindowSize(PromptSettings s) => switch (s.placement) {
  PromptPlacement.notch => Size(s.notchSize.width, s.notchSize.height),
  PromptPlacement.corner => s.cornerSize,
  PromptPlacement.floating => const Size(900, 360),
};

/// What the prompter will look like, drawn by the same [PromptSurface] the real
/// prompter uses, at the real window size and scaled to fit. Changing any text
/// setting, the opacity or the position updates it immediately.
///
/// It is static: it never scrolls, listens or highlights, and it ignores the
/// live session. [wordIndex] is the word shown on the reading line, normally
/// the one under the editor's caret.
class PromptPreview extends ConsumerStatefulWidget {
  const PromptPreview({super.key, required this.wordIndex, this.height});

  final int wordIndex;

  /// Fixed height; by default the preview is 16:10 at whatever width it gets.
  final double? height;

  @override
  ConsumerState<PromptPreview> createState() => _PromptPreviewState();
}

class _PromptPreviewState extends ConsumerState<PromptPreview> {
  late String _script = ref.read(studioProvider).script;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-laying out a long script on every keystroke is wasteful; follow the
    // editor a moment after typing stops.
    ref.listen(studioProvider.select((s) => s.script), (_, next) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _script = next);
      });
    });
    final s = ref.watch(settingsProvider);
    final size = promptWindowSize(s);
    final style = switch (s.placement) {
      PromptPlacement.notch => PromptLayoutStyle.notch,
      PromptPlacement.corner => PromptLayoutStyle.compact,
      PromptPlacement.floating => PromptLayoutStyle.full,
    };

    final surface = PromptSurface(
      style: style,
      previewWordIndex: widget.wordIndex,
      scriptOverride: _script,
    );

    final Widget window = s.placement == PromptPlacement.notch
        ? ClipPath(
            clipper: const NotchClipper(),
            child: ColoredBox(
              color: promptBackground.withValues(alpha: s.opacity),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NotchClipper.flare),
                child: surface,
              ),
            ),
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: ColoredBox(color: promptBackground.withValues(alpha: s.opacity), child: surface),
            ),
          );

    final alignment = switch (s.placement) {
      PromptPlacement.notch => Alignment.topCenter,
      PromptPlacement.corner => switch (s.corner) {
        PromptCorner.topLeft => Alignment.topLeft,
        PromptCorner.topRight => Alignment.topRight,
        PromptCorner.bottomLeft => Alignment.bottomLeft,
        PromptCorner.bottomRight => Alignment.bottomRight,
      },
      PromptPlacement.floating => Alignment.center,
    };

    Widget sized(Widget child) =>
        widget.height == null ? AspectRatio(aspectRatio: 16 / 10, child: child) : SizedBox(height: widget.height, child: child);

    return Semantics(
      label: 'Live preview of the prompter',
      child: sized(
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            // A mid-tone desktop so a see-through prompter reads as see-through.
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF5B7FA6), Color(0xFF8E6FA8)],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(
                left: 10,
                right: 10,
                bottom: 10,
                top: s.placement == PromptPlacement.notch ? 0 : 10,
              ),
              child: Align(
                alignment: alignment,
                child: FittedBox(
                  fit: BoxFit.contain,
                  alignment: alignment,
                  child: SizedBox(width: size.width, height: size.height, child: window),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
