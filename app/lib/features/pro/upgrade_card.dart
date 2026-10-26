import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/entitlements/entitlements.dart';
import 'paywall_dialog.dart';
import 'pro_state.dart';

/// Pinned to the bottom of the Script Studio sidebar for free users, so buying Pro is one click from the
/// home screen. It grows and turns amber when the free scripts run out. Hidden for Pro.
class UpgradeCard extends ConsumerWidget {
  const UpgradeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pro = ref.watch(proProvider);
    if (pro.isPro) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Only when the limit is really switched on does running out mean anything.
    final limit = proEnforced && pro.limitReached;
    final used = pro.used.clamp(0, freeScriptLimit);

    final button = FilledButton(
      onPressed: () => showPaywall(context),
      style: FilledButton.styleFrom(
        backgroundColor: proAccent,
        foregroundColor: const Color(0xFF1A1A1A),
        minimumSize: Size.fromHeight(limit ? 40 : 34),
        textStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: limit ? 14 : 13),
      ),
      child: const Text('Upgrade to Pro…'),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      padding: EdgeInsets.all(limit ? 14 : 12),
      decoration: BoxDecoration(
        color: limit ? const Color(0xFF33291A) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: limit ? proAccent : scheme.outlineVariant, width: limit ? 1.5 : 1),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.star_rounded, size: limit ? 18 : 16, color: proAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              limit ? 'All $freeScriptLimit free scripts used' : 'Free plan',
              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (!limit)
            Text('$used of $freeScriptLimit scripts used', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: used / freeScriptLimit,
          minHeight: 4,
          color: proAccent,
          backgroundColor: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(2),
        ),
        if (limit) ...[
          const SizedBox(height: 8),
          Text('Upgrade to present new scripts. Your $freeScriptLimit scripts still work.', style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 10),
        button,
        if (limit) ...[
          const SizedBox(height: 6),
          Text(
            'From ${ProPrices.yearlyPerMonth} a month, billed yearly',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ]),
    );
  }
}
