import 'package:flutter/widgets.dart';

import '../routing/app_router.dart';
import '../screens/main_shell_screen.dart';

/// Bumped to force the whole [MaterialApp.router] subtree to rebuild from
/// scratch. The app root ([AymaApp]) keys its router subtree on this value, so
/// a bump re-mounts the Router + Navigator even when the previous tree was
/// replaced wholesale by the global `ErrorWidget.builder` (a build threw high
/// enough to take out the Router itself — at which point `appRouter.go` alone
/// can't change the frame, because its delegate is no longer mounted).
final ValueNotifier<int> appRecoveryEpoch = ValueNotifier<int>(0);

/// Recover from a stranded error screen (SWEEP91-J1R S2 / J1): CLEAR the route
/// that threw and land Home, and force the root to rebuild — so the frame
/// changes regardless of how high the failed subtree was, and the throwing
/// route is gone afterwards (not merely re-rendered). Best-effort and never
/// throws — it is called from the context-free error fallback, where the
/// normal tree may be broken.
///
/// J1: the throw replaced the whole `/deep-dive/:id` route (a pushed route),
/// leaving a chromeless dead-end. `go(Home)` replaces the entire navigation
/// stack with a single Home entry, so the pushed `/deep-dive` entry is dropped
/// — Home renders at most the compact "Web research report" chat button for
/// that dive, never the report view that threw, so it cannot re-throw.
void recoverAppRoot() {
  // 1. Re-point the router at Home, clearing the stack, BEFORE the rebuild — so
  //    the common case re-mounts straight onto Home with no error flash.
  try {
    appRouter.go(MainShellScreen.path);
  } catch (_) {/* router may be detached; the epoch bump below still recovers */}
  // 2. Force [AymaApp] to rebuild its keyed router subtree from scratch, so the
  //    frame changes even when the failed build took out the Router itself.
  try {
    appRecoveryEpoch.value = appRecoveryEpoch.value + 1;
  } catch (_) {/* nothing more we can safely do */}
  // 3. Re-assert Home AFTER the fresh Router has mounted and is listening. If
  //    the re-mounted Router restored the delegate's stale `/deep-dive`
  //    matchlist instead of re-reading the provider (which would re-render and
  //    re-throw — the stranding QA saw where step 1 alone did not recover),
  //    this post-frame hop drives it back to Home. Scheduled on the binding,
  //    not the widget tree, so it fires even if the rebuilt frame itself threw.
  try {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        appRouter.go(MainShellScreen.path);
      } catch (_) {/* best effort */}
    });
  } catch (_) {/* binding unavailable (unit test without a binding) */}
}
