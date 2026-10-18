
import '../services/platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings/labels.dart';
import '../core/settings/prompt_settings.dart';
import '../services/providers.dart';

/// Notch widths offered in Studio and in the prompter's position menu.
const notchWidths = [('Small', 440.0), ('Medium', 560.0), ('Large', 760.0)];

/// Where the prompter sits: three picture tiles, plus the choice that goes
/// with the selected tile (corner or notch width).
class PositionPicker extends ConsumerWidget {
  const PositionPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final hasNotch = ref.watch(hasNotchProvider).value ?? false;
    final set = ref.read(settingsProvider.notifier).update;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final p in PromptPlacement.values) ...[
              if (p != PromptPlacement.values.first) const SizedBox(width: 8),
              Expanded(
                child: _PositionTile(
                  placement: p,
                  corner: s.corner,
                  label: p.label(hasNotch: hasNotch),
                  selected: s.placement == p,
                  onTap: () => set((c) => c.copyWith(placement: p)),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          s.placement.description(hasNotch: hasNotch, mac: isMacOS),
          style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        if (s.placement == PromptPlacement.corner) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              CornerPicker(selected: s.corner, onSelected: (c) => set((v) => v.copyWith(corner: c))),
              const SizedBox(width: 12),
              Text(s.corner.label, style: text.labelLarge),
            ],
          ),
        ],
        if (s.placement == PromptPlacement.notch) ...[
          const SizedBox(height: 10),
          SegmentedButton<double>(
            showSelectedIcon: false,
            segments: [for (final (name, w) in notchWidths) ButtonSegment(value: w, label: Text(name))],
            selected: {
              notchWidths.map((e) => e.$2).firstWhere((w) => w == s.notchSize.width, orElse: () => notchWidths[1].$2),
            },
            onSelectionChanged: (v) => set((c) => c.copyWith(notchSize: Size(v.first, c.notchSize.height))),
          ),
        ],
      ],
    );
  }
}

class _PositionTile extends StatelessWidget {
  const _PositionTile({
    required this.placement,
    required this.corner,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final PromptPlacement placement;
  final PromptCorner corner;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label position',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: CustomPaint(
                  painter: _MiniScreenPainter(
                    placement: placement,
                    corner: corner,
                    screen: scheme.surfaceContainerHighest,
                    outline: scheme.outline,
                    prompter: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny screen with the prompter drawn where it would sit.
class _MiniScreenPainter extends CustomPainter {
  _MiniScreenPainter({
    required this.placement,
    required this.corner,
    required this.screen,
    required this.outline,
    required this.prompter,
  });

  final PromptPlacement placement;
  final PromptCorner corner;
  final Color screen;
  final Color outline;
  final Color prompter;

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(5));
    canvas.drawRRect(body, Paint()..color = screen);
    canvas.drawRRect(body, Paint()..color = outline..style = PaintingStyle.stroke..strokeWidth = 1);
    final fill = Paint()..color = prompter;
    final w = size.width, h = size.height;
    switch (placement) {
      case PromptPlacement.notch:
        final r = Rect.fromLTWH(w * 0.28, 0, w * 0.44, h * 0.34);
        canvas.drawRRect(
          RRect.fromRectAndCorners(r, bottomLeft: const Radius.circular(6), bottomRight: const Radius.circular(6)),
          fill,
        );
      case PromptPlacement.corner:
        final cw = w * 0.34, ch = h * 0.34, m = w * 0.06;
        final left = corner == PromptCorner.topLeft || corner == PromptCorner.bottomLeft;
        final top = corner == PromptCorner.topLeft || corner == PromptCorner.topRight;
        final r = Rect.fromLTWH(left ? m : w - m - cw, top ? m : h - m - ch, cw, ch);
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), fill);
      case PromptPlacement.floating:
        final r = Rect.fromLTWH(w * 0.2, h * 0.3, w * 0.6, h * 0.4);
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), fill);
    }
  }

  @override
  bool shouldRepaint(_MiniScreenPainter o) =>
      o.placement != placement || o.corner != corner || o.screen != screen || o.prompter != prompter;
}

/// A 2×2 miniature screen for choosing the prompter corner.
class CornerPicker extends StatelessWidget {
  const CornerPicker({super.key, required this.selected, required this.onSelected});

  final PromptCorner selected;
  final ValueChanged<PromptCorner> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(PromptCorner c) => Expanded(
      child: Semantics(
        button: true,
        selected: c == selected,
        label: c.label,
        child: InkWell(
          onTap: () => onSelected(c),
          child: Container(
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: c == selected ? scheme.primary : scheme.surfaceContainerHigh,
            ),
          ),
        ),
      ),
    );
    return Container(
      width: 84,
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        children: [
          Expanded(child: Row(children: [cell(PromptCorner.topLeft), cell(PromptCorner.topRight)])),
          Expanded(child: Row(children: [cell(PromptCorner.bottomLeft), cell(PromptCorner.bottomRight)])),
        ],
      ),
    );
  }
}
