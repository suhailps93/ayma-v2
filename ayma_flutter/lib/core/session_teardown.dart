import 'dart:async';

import 'package:flutter/widgets.dart';

import '../routing/app_router.dart';
import '../screens/sign_in_screen.dart';
import '../screens/splash_screen.dart';
import '../services/app_context.dart';
import '../services/auth_session_state.dart';
import '../services/ayma_session.dart';
import '../services/biometric_consent.dart';
import '../services/credits_balance.dart';
import '../services/deep_dive_activity.dart';
import '../services/deep_link_queue.dart';
import '../services/dev_panel_session.dart';
import '../services/match_activity.dart';
import '../services/match_report_cache.dart';
import '../services/push_service.dart';
import '../services/report_cache.dart';
import '../services/revenuecat_service.dart';
import '../services/screen_capture.dart';
import '../services/tab_prefetch_coordinator.dart';
import '../widgets/ask_ayma_overlay.dart';
import 'app_recovery.dart';

/// Centralized navigation + in-memory teardown executed whenever the signed-in
/// session ends (sign-out / forced 401) or switches to a different account.
///
/// This is the systemic root fix for the ghost-header / cross-account route
/// lingering incidents (R2-C6 / R2-C7): on an auth transition the root
/// `Navigator` stack and the app-wide singletons are not otherwise torn down,
/// so Account A's story, DMs, reports, credits and live voice can linger into
/// Account B. The epoch bump (step 3) unmounts the entire router/navigator
/// subtree — including the cached main-shell tabs and any pushed routes —
/// while the explicit singleton purge (step 2) clears the state that lives
/// outside the widget tree.
///
/// What deliberately SURVIVES teardown (device/environment, never per-account):
/// theme and accent controllers, compile-time flags, localization delegates,
/// and the global route observers / navigator keys. None of those are touched
/// here. See ghost-header spec §5.2.
///
/// Each step that could fail independently is wrapped so one failure cannot
/// abort the rest of the teardown.
void teardownSession({required bool isSwitch}) {
  // 1. Cancel realtime voice & dismiss any open Ayma popup/overlay.
  try {
    unawaited(AymaSession.instance.voice.stop().catchError((_) {}));
  } catch (_) {}
  try {
    // The page-context Ayma popup is a modal route on the root navigator; the
    // epoch bump below would discard it regardless, but dismiss it explicitly
    // so its `finally` resets the `isAymaSheetOpen` flag cleanly.
    if (isAymaSheetOpen) {
      unawaited(
        (screenPopupTracker.navigator?.maybePop() ?? Future<bool>.value(false))
            .catchError((_) => false),
      );
    }
  } catch (_) {}

  // 2. Purge in-memory caches, singletons and in-flight job markers.
  AymaSession.instance.store.clear();
  TabPrefetchCoordinator.instance.clear();
  CreditsBalance.instance.remaining.value = null;
  MatchReportCache.instance.clearAll();
  DeepDiveActivity.instance.searching.value = const {};
  DeepDiveActivity.instance.failed.value = const {};
  MatchActivity.instance.recalculating.value = const {};
  DeepLinkQueue.instance.clearPendingIntent();
  AppContext.instance.clear();
  RecoveryRequiredState.instance.clear();
  BiometricConsentState.instance.clear();
  DevPanelSession.instance.unlocked.value = false;

  // Disk cache, RevenueCat and push-token cleanup each reach an external
  // transport whose construction/handshake can throw; isolate them so one
  // failure never skips the navigation reset below.
  try {
    unawaited(ReportCache.instance.clearForSignOut());
  } catch (_) {}
  try {
    unawaited(RevenueCatService.instance.logOut());
  } catch (_) {}
  try {
    unawaited(PushService().clearToken());
  } catch (_) {}

  // 3. Reset navigation & rebuild the entire router/navigator subtree.
  final target = isSwitch ? SplashScreen.path : SignInScreen.path;
  try {
    appRouter.go(target);
  } catch (_) {}

  appRecoveryEpoch.value = appRecoveryEpoch.value + 1;

  try {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        appRouter.go(target);
      } catch (_) {}
    });
  } catch (_) {}

  // 4. Update the router-facing auth session notifier (fires refreshListenable
  //    so GoRouter's redirect re-evaluates the sign-in gate immediately).
  AuthSessionState.instance.clear();
}
