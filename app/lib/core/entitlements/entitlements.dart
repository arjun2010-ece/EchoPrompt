import '../script/saved_script.dart';

/// Paywall seam. Phase 3 replaces [UnlockedEntitlements] with the real state
/// machine; call sites already go through this interface.
abstract class Entitlements {
  bool get isPro;
  bool canStartPrompter(SavedScript script);
}

class UnlockedEntitlements implements Entitlements {
  const UnlockedEntitlements();
  @override
  bool get isPro => true;
  @override
  bool canStartPrompter(SavedScript script) => true;
}

/// Whether the free-script limit is enforced. Off until billing is connected (plan Phase 3): the Pro screens
/// work and free scripts are counted, but nothing is locked, so every build presents as before.
const proEnforced = false;

/// Scripts a free user may present.
const freeScriptLimit = 5;

enum ProPlan { free, monthly, yearly, lifetime }

/// Prices shown on the paywall; the stores will supply them in the user's currency once purchases are connected.
class ProPrices {
  const ProPrices._();
  static const monthly = '€6.99';
  static const yearly = '€55';
  static const yearlyPerMonth = '€4.58';
  static const lifetime = '€109.99';
}

class ProState {
  const ProState({this.presented = const {}, this.plan = ProPlan.free});

  /// Ids of the scripts presented so far; a script counts the first time it is presented.
  final Set<String> presented;
  final ProPlan plan;

  bool get isPro => plan != ProPlan.free;
  int get used => presented.length;

  /// A free user has presented all [freeScriptLimit] scripts and is no longer allowed a new one.
  bool get limitReached => !isPro && used >= freeScriptLimit;

  /// Whether the script with [id] (null: a script not presented before) may be presented.
  bool canPresent(String? id) => !proEnforced || isPro || (id != null && presented.contains(id)) || used < freeScriptLimit;

  ProState copyWith({Set<String>? presented, ProPlan? plan}) =>
      ProState(presented: presented ?? this.presented, plan: plan ?? this.plan);
}
