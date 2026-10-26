import 'package:flutter/material.dart';

import '../../core/entitlements/entitlements.dart';
import '../../services/external_links.dart';

/// Opens the plans. [reason] sits under the title when the paywall came from a locked Start.
Future<void> showPaywall(BuildContext context, {String? reason}) =>
    showDialog<void>(context: context, builder: (_) => PaywallDialog(reason: reason));

/// Pro accent: amber, so the buy path stands apart from the blue Start button.
const proAccent = Color(0xFFFFB340);

String _planName(ProPlan p) => switch (p) {
  ProPlan.monthly => 'Monthly',
  ProPlan.yearly => 'Yearly',
  ProPlan.lifetime => 'Lifetime',
  ProPlan.free => 'Free',
};

class PaywallDialog extends StatefulWidget {
  const PaywallDialog({super.key, this.reason});
  final String? reason;

  @override
  State<PaywallDialog> createState() => _PaywallDialogState();
}

class _PaywallDialogState extends State<PaywallDialog> {
  // Yearly is the default: best value, and a year of revenue up front.
  ProPlan _plan = ProPlan.yearly;
  String? _notice;

  String get _buyLabel => switch (_plan) {
    ProPlan.monthly => 'Subscribe for ${ProPrices.monthly} a month',
    ProPlan.yearly => 'Subscribe for ${ProPrices.yearly} a year',
    ProPlan.lifetime => 'Buy Lifetime for ${ProPrices.lifetime}',
    ProPlan.free => '',
  };

  // Purchases connect in plan Phase 3. Until then the buttons say so instead of doing nothing.
  void _unavailable(String what) => setState(() => _notice = '$what isn\'t available in this build yet.');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: proAccent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.star_rounded, size: 32, color: proAccent),
              ),
            ),
            const SizedBox(height: 14),
            Text('Upgrade to EchoPrompter Pro', textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              widget.reason == null
                  ? 'Present as many scripts as you like, on all your devices.'
                  : '${widget.reason} Pro lets you present as many as you like, on all your devices.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (final line in const [
              'Unlimited scripts in the prompter',
              'One purchase for up to 5 devices when you sign in',
              'Writing, editing and exporting stay free',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  const Icon(Icons.check_rounded, size: 18, color: Color(0xFF30D158)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(line)),
                ]),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _PlanCard(plan: ProPlan.monthly, price: ProPrices.monthly, line1: 'per month', line2: 'cancel anytime', selected: _plan, onSelect: _select)),
              const SizedBox(width: 10),
              Expanded(child: _PlanCard(plan: ProPlan.yearly, price: ProPrices.yearly, line1: 'per year', line2: 'about ${ProPrices.yearlyPerMonth} a month', badge: 'SAVE 34%', selected: _plan, onSelect: _select)),
              const SizedBox(width: 10),
              Expanded(child: _PlanCard(plan: ProPlan.lifetime, price: ProPrices.lifetime, line1: 'one payment', line2: 'Pro forever', selected: _plan, onSelect: _select)),
            ]),
            if (_notice != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8), border: Border.all(color: scheme.outlineVariant)),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_notice!, style: theme.textTheme.bodySmall)),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _unavailable('Buying Pro'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              child: Text(_buyLabel),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton(onPressed: () => _unavailable('Restoring purchases'), child: const Text('Restore Purchases')),
              const SizedBox(width: 12),
              TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Not Now')),
            ]),
            Text(
              'Prices are shown in your store\'s currency. Monthly and Yearly renew until you cancel them in your store settings. '
              'Questions? $supportEmail',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
      ),
    );
  }

  void _select(ProPlan p) => setState(() {
    _plan = p;
    _notice = null;
  });
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.price, required this.line1, required this.line2, required this.selected, required this.onSelect, this.badge});
  final ProPlan plan;
  final String price;
  final String line1;
  final String line2;
  final String? badge;
  final ProPlan selected;
  final void Function(ProPlan) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = plan == selected;
    return Semantics(
      button: true,
      selected: on,
      label: '${_planName(plan)}, $price, $line1',
      child: InkWell(
        onTap: () => onSelect(plan),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: on ? scheme.primary.withValues(alpha: 0.14) : scheme.surfaceContainerHigh,
            border: Border.all(color: on ? scheme.primary : scheme.outlineVariant, width: on ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(_planName(plan), style: theme.textTheme.labelLarge),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFF1E3A26), borderRadius: BorderRadius.circular(5)),
                  child: Text(badge!, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF30D158))),
                ),
              ],
            ]),
            const SizedBox(height: 4),
            Text(price, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('$line1\n$line2', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

/// Shown when a subscription hasn't been checked for 30 days (plan §10.4). Wired in with billing (Phase 3).
Future<void> showSubscriptionCheckAlert(BuildContext context) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    icon: const Icon(Icons.warning_amber_rounded, size: 32, color: proAccent),
    title: const Text('Connect to check your subscription'),
    content: const Text(
      'EchoPrompter checks your Pro subscription at least every 30 days. Connect to the internet to keep presenting. '
      'It checks again on its own as soon as you\'re online.',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Not Now')),
      FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Try Again')),
    ],
  ),
);
