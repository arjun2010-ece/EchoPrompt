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
