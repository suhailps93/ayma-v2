import 'package:flutter/foundation.dart';

import '../routing/app_router.dart';
import '../screens/main_shell_screen.dart';

/// Bumped to force the whole [MaterialApp.router] subtree to rebuild from
/// scratch. The app root ([AymaApp]) keys its router subtree on this value, so
/// a bump re-mounts the Router + Navigator even when the previous tree was
/// replaced wholesale by the global `ErrorWidget.builder` (a build threw high
/// enough to take out the Router itself — at which point `appRouter.go` alone
/// can't change the frame, because its delegate is no longer mounted).
final ValueNotifier<int> appRecoveryEpoch = ValueNotifier<int>(0);

/// Recover from a stranded error screen (SWEEP91-J1R S2): reset the route to a
/// safe home AND force the root to rebuild, so the frame changes regardless of
/// how high the failed subtree was. Best-effort and never throws — it is called
/// from the context-free error fallback, where the normal tree may be broken.
void recoverAppRoot() {
  // Re-point the router at a safe destination first, so the rebuilt tree lands
  // Home rather than re-mounting the same broken route.
  try {
    appRouter.go(MainShellScreen.path);
  } catch (_) {/* router may be detached; the epoch bump below still recovers */}
  // Force [AymaApp] to rebuild its keyed router subtree from scratch.
  try {
    appRecoveryEpoch.value = appRecoveryEpoch.value + 1;
  } catch (_) {/* nothing more we can safely do */}
}
