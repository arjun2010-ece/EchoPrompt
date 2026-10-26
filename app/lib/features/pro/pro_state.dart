import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/entitlements/entitlements.dart';
import '../../services/providers.dart';

const _proKey = 'EchoPrompter.proState.v1';

/// Free-script counter and plan. Purchases aren't connected yet, so the plan stays Free outside debug
/// builds; the counter is kept now so the numbers are right when the limit is switched on.
class ProNotifier extends Notifier<ProState> {
  @override
  ProState build() {
    final raw = ref.read(prefsProvider).getString(_proKey);
    if (raw == null) return const ProState();
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      return ProState(presented: {...(j['presented'] as List? ?? const []).cast<String>()});
    } catch (_) {
      return const ProState();
    }
  }

  void _save() => ref.read(prefsProvider).setString(_proKey, jsonEncode({'presented': state.presented.toList()}));

  /// Counts the script with [id] as presented, once.
  void recordStart(String id) {
    if (state.presented.contains(id)) return;
    state = state.copyWith(presented: {...state.presented, id});
    _save();
  }

  /// Debug builds only: preview the Pro screens in each state. Never saved.
  void previewPlan(ProPlan plan) => state = state.copyWith(plan: plan);
}

final proProvider = NotifierProvider<ProNotifier, ProState>(ProNotifier.new);
