import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings/labels.dart';
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

/// Text size, line spacing, background opacity and the reading guide. The one
/// place these are edited, used by Script Studio and by the prompter's "Aa"
/// popover, so both always agree on ranges and wording. With [collapsible]
/// only the size shows until "More text options" is opened (Script Studio's
/// inspector, which is short on room); the popover shows everything.
class PromptTextControls extends ConsumerStatefulWidget {
  const PromptTextControls({super.key, this.showOpacity = true, this.collapsible = false});

  final bool showOpacity;
  final bool collapsible;

  @override
  ConsumerState<PromptTextControls> createState() => _PromptTextControlsState();
}

class _PromptTextControlsState extends ConsumerState<PromptTextControls> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).update;
    final theme = Theme.of(context);
    final showMore = !widget.collapsible || _more;
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
        if (widget.collapsible)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _more = !_more),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 28)),
              icon: AnimatedRotation(
                turns: _more ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(Icons.chevron_right, size: 18),
              ),
              label: Text.rich(TextSpan(children: [
                const TextSpan(text: 'More text options'),
                if (!_more)
                  TextSpan(
                    text: '   Font, spacing, margins',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ])),
            ),
          ),
        if (showMore) ...[
          _OptionRow(
            label: 'Font',
            child: DropdownButton<PromptFont>(
              value: s.font,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final f in PromptFont.values)
                  DropdownMenuItem(
                    value: f,
                    child: Text(f.label, style: TextStyle(fontFamily: f.family)),
                  ),
              ],
              onChanged: (v) => v == null ? null : set((c) => c.copyWith(font: v)),
            ),
          ),
          LabeledSlider(
            label: 'Line spacing',
            valueLabel: '${s.lineSpacing.toStringAsFixed(2)}×',
            value: s.lineSpacing,
            min: PromptLimits.lineSpacing.min,
            max: PromptLimits.lineSpacing.max,
            onChanged: (v) => set((c) => c.copyWith(lineSpacing: v)),
          ),
          _OptionRow(
            label: 'Margins',
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: SegmentedButton<PromptMargins>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [for (final m in PromptMargins.values) ButtonSegment(value: m, label: Text(m.label))],
                selected: {s.margins},
                onSelectionChanged: (v) => set((c) => c.copyWith(margins: v.first)),
              ),
            ),
          ),
          if (widget.showOpacity)
            LabeledSlider(
              label: 'Background opacity',
              valueLabel: '${(s.opacity * 100).round()}%',
              value: s.opacity,
              min: PromptLimits.opacity.min,
              max: PromptLimits.opacity.max,
              onChanged: (v) => set((c) => c.copyWith(opacity: v)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Reading guide'),
            subtitle: const Text('Marks the line you read on'),
            value: s.readingGuide,
            onChanged: (v) => set((c) => c.copyWith(readingGuide: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Show progress'),
            subtitle: const Text('Percent, time elapsed and time left'),
            value: s.showProgress,
            onChanged: (v) => set((c) => c.copyWith(showProgress: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Show sections'),
            subtitle: const Text('Names between parts of the script'),
            value: s.showSections,
            onChanged: (v) => set((c) => c.copyWith(showSections: v)),
          ),
        ],
      ],
    );
  }
}

/// A label with a control beside it, for options that aren't sliders.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      SizedBox(width: 96, child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
      Expanded(child: child),
    ]),
  );
}

/// "Reset to Defaults" for the text options; disabled when there's nothing to reset.
class ResetTextButton extends ConsumerWidget {
  const ResetTextButton({super.key, this.label = 'Reset'});
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDefault = ref.watch(settingsProvider.select((s) => s.isTextDefault));
    return TextButton(
      onPressed: isDefault ? null : ref.read(settingsProvider.notifier).resetText,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: Text(label),
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
