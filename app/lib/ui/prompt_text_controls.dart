import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings/prompt_settings.dart';
import '../services/providers.dart';

/// A labelled slider whose value is shown beside the label.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(label, style: text.labelLarge),
            const Spacer(),
            Text(valueLabel, style: text.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ],
        ),
        Slider(
          min: min,
          max: max,
          value: value.clamp(min, max).toDouble(),
          semanticFormatterCallback: (_) => '$label $valueLabel',
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Text size, line spacing and background opacity. The one place these
/// are edited, used by Script Studio and by the prompter's "Aa" popover, so
/// both always agree on ranges and wording.
class PromptTextControls extends ConsumerWidget {
  const PromptTextControls({super.key, this.showOpacity = true});

  final bool showOpacity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        LabeledSlider(
          label: 'Text size',
          valueLabel: '${s.fontSize.round()} pt',
          value: s.fontSize,
          min: PromptLimits.fontSize.min,
          max: PromptLimits.fontSize.max,
          onChanged: (v) => set((c) => c.copyWith(fontSize: v)),
        ),
        LabeledSlider(
          label: 'Line spacing',
          valueLabel: '${s.lineSpacing.toStringAsFixed(2)}×',
          value: s.lineSpacing,
          min: PromptLimits.lineSpacing.min,
          max: PromptLimits.lineSpacing.max,
          onChanged: (v) => set((c) => c.copyWith(lineSpacing: v)),
        ),
        if (showOpacity)
          LabeledSlider(
            label: 'Background opacity',
            valueLabel: '${(s.opacity * 100).round()}%',
            value: s.opacity,
            min: PromptLimits.opacity.min,
            max: PromptLimits.opacity.max,
            onChanged: (v) => set((c) => c.copyWith(opacity: v)),
          ),
      ],
    );
  }
}

/// Normal-mode scroll speed.
class ScrollSpeedControl extends ConsumerWidget {
  const ScrollSpeedControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(settingsProvider.select((s) => s.speed));
    return LabeledSlider(
      label: 'Scroll speed',
      valueLabel: '${speed.round()} px/s',
      value: speed,
      min: PromptLimits.speed.min,
      max: PromptLimits.speed.max,
      onChanged: (v) => ref.read(settingsProvider.notifier).update((c) => c.copyWith(speed: v)),
    );
  }
}
