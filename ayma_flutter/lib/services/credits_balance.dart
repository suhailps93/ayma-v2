import 'package:flutter/foundation.dart';

/// App-wide cache of the account's last-known credit balance.
///
/// The Profile tab's "Credits" row (`profile_tab_screen.dart`'s
/// `_CreditsBalance`) fetches once in `initState` and, being kept alive
/// inside the tab shell, never refetches again for the app's lifetime — so a
/// reload done on the full Plan screen (`plan_screen.dart`) never reached
/// it, leaving that row showing a stale (often zero, from before the first
/// top-up) number while the real balance had already moved on (§ founder
/// report: "Account have 83 credits but here it shows zero"). Any screen
/// that fetches `/usage` writes the fresh number here; any screen showing a
/// balance reads it via [remaining] instead of keeping its own private
/// fetch-once cache, so every surface stays in sync with the last fetch
/// *anywhere*, not just its own.
class CreditsBalance {
  CreditsBalance._();
  static final CreditsBalance instance = CreditsBalance._();

  final ValueNotifier<int?> remaining = ValueNotifier(null);
}
