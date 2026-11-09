import 'dart:async';

import 'package:country_picker/country_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:logging/logging.dart';

import 'core/app_recovery.dart';
import 'core/dag/launch_intent_resolver.dart';
import 'core/dag/startup_nodes.dart';
import 'core/session_teardown.dart';
import 'routing/app_router.dart';
import 'services/accent_color_controller.dart';
import 'services/auth_service.dart';
import 'services/auth_session_state.dart';
import 'services/deep_link_queue.dart';
import 'services/install_referrer_service.dart';
import 'services/push_service.dart';
import 'services/revenuecat_service.dart';
import 'services/theme_controller.dart';
import 'services/ui_stall_watchdog.dart';
import 'theme.dart';
import 'widgets/ayma_toast.dart';
import 'widgets/connection_banner.dart';
import 'widgets/keyboard_dismiss.dart';
import 'widgets/tour_host.dart';

Future<void> main() async {
  // Route LiveKit's internal client logs in debug builds
  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(
      (r) => debugPrint('[${r.loggerName}] ${r.level.name}: ${r.message}'),
    );
  }

  final dag = StartupNodes.buildDefaultDAG(
    app: const AymaApp(),
    router: appRouter,
  );

  // Extract initial launch intent and dynamically configure critical path
  final intent = await LaunchIntentResolver.extract();
  LaunchIntentResolver.configureDAGForIntent(dag, intent);

  // Run pre-frame DAG to first frame mount (N8:first_frame_mount). N8 depends
  // (transitively) on N7:firebase_core, so once this returns Firebase is
  // guaranteed initialized. The ongoing session listeners below all touch
  // Firebase (PushService → FirebaseMessaging.instance, FirebaseAuth) and MUST
  // NOT be registered before this point: registering them at the top of main()
  // — before the DAG ran N7 — was the P0 boot crash (`PushService()` threw
  // `[core/no-app]`, aborting main() on the splash). See startup_nodes_test.dart
  // for the "run-to-N8 guarantees N7" regression guard.
  await dag.run(targetNodes: {'N8:first_frame_mount'});

  // From the first frame on, record any frame that stalls the UI thread
  // (NOTE 133: the 02:41 ANR's trace was taken after the blocking work
  // finished, so the block was never named — a stall now logs its phase
  // split in logcat at the moment it happens).
  UiStallWatchdog.instance.start();

  // Firebase is up. Register the ongoing session listeners that depend on it.
  // N9:auth_session_restore blocks on `notifyAuthSessionRestored` (fired by the
  // auth listener below) — it is not on the path to N8, so it resolves here,
  // once the listener is live, and its dependent nodes (routing, boot config,
  // RevenueCat bind, push sync) then run in the background.
  final push = PushService();
  setupAuthDeepLinkDrain();
  unawaited(InstallReferrerService.instance.checkInstallReferrer());

  String? lastKnownUid;
  FirebaseAuth.instance.authStateChanges().listen((user) {
    if (user == null) {
      // Only tear down when a real session actually ended. On cold start
      // `lastKnownUid` is null (the initial settling tick before KeyStore
      // token decryption finishes), so legitimate users are never stranded on
      // SignIn — see ghost-header spec §8.1. [teardownSession] handles the
      // per-account gate/cache/RevenueCat clears that used to live here.
      if (lastKnownUid != null) {
        teardownSession(isSwitch: false);
      }
      lastKnownUid = null;
      AuthSessionState.instance.clear();
      AuthService.instance.notifyAuthSessionRestored(null);
    } else {
      // A different account signed in while one was already active: tear the
      // previous account's nav stack and singletons down before binding the
      // new session (ghost-header spec §5.1).
      final isSwitch = lastKnownUid != null && lastKnownUid != user.uid;
      if (isSwitch) {
        teardownSession(isSwitch: true);
      }
      lastKnownUid = user.uid;
      AuthSessionState.instance.update(signedIn: true, uid: user.uid);
      AuthService.instance.notifyAuthSessionRestored(user);
      unawaited(RevenueCatService.instance.logIn(user.uid));
      unawaited(push.syncToken());
      unawaited(DeepLinkQueue.instance.drainPostAuth(
        user.uid,
        navigate: (path) => navigateToRoute(path),
      ));
    }
  });

  unawaited(push.listenForTaps(
    navigate: (path) => navigateToRoute(path),
    queue: DeepLinkQueue.instance,
    router: appRouter,
    authService: AuthService.instance,
  ));
}

/// Runs a pre-first-frame startup step under a hard deadline.
/// Preserved as @visibleForTesting for backward compatibility with [startup_guard_test.dart].
@visibleForTesting
Future<void> guardStartupStep(
  String label,
  Future<void> Function() step, {
  Duration limit = const Duration(seconds: 8),
}) async {
  try {
    await step().timeout(limit);
  } on TimeoutException {
    debugPrint('startup: "$label" timed out after '
        '${limit.inSeconds}s; continuing to runApp.');
  } catch (e) {
    debugPrint('startup: "$label" failed ($e); continuing to runApp.');
  }
}

/// Root of the Ayma app.
///
/// Step 4: `go_router` with placeholder screens (splash / preboarding / main
/// shell). Real redirect logic and the 4-tab shell come later.
class AymaApp extends StatelessWidget {
  const AymaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Keyed on [appRecoveryEpoch] so the error fallback's "Go back" can force a
    // full rebuild of the router subtree — re-mounting the Router/Navigator
    // even when a build threw high enough to take out the whole app tree
    // (SWEEP91-J1R S2). A bump changes the KeyedSubtree key, which discards and
    // rebuilds everything below it.
    return ValueListenableBuilder<int>(
      valueListenable: appRecoveryEpoch,
      builder: (context, epoch, _) => KeyedSubtree(
        key: ValueKey<int>(epoch),
        child: _buildRouterApp(context),
      ),
    );
  }

  Widget _buildRouterApp(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        themeControllerGlobal,
        accentColorControllerGlobal,
      ]),
      builder: (context, _) => MaterialApp.router(
        title: 'Ayma',
        debugShowCheckedModeBanner: false,
        theme: AymaTheme.lightWithAccent(accentColorControllerGlobal.color),
        darkTheme: AymaTheme.darkWithAccent(accentColorControllerGlobal.color),
        themeMode: themeControllerGlobal.mode,
        // For the country-code picker's search UI.
        localizationsDelegates: const [
          CountryLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: appRouter,
        // App-wide "tap outside a text field to dismiss the keyboard" —
        // iOS keyboards have no dismiss key (founder issue). A pure
        // pointer-event observer, so it cannot steal or delay any tap in
        // the tree — see [KeyboardDismissOnTap]'s doc.
        // [AymaToastHost] renders app-wide toasts above every route.
        // [TourHost] is OUTERMOST so the interactive feature-tour overlay
        // (§11.2a) sits above the Navigator — and so above every route it
        // pushes — and stays mounted as the tour walks between pages (it is
        // idle, adding nothing, until the shell's gate starts a tour).
        builder: (context, child) => TourHost(
          child: AymaToastHost(
            // [ConnectionBanner] renders the offline/weak strip above every
            // routed page (and passes the child through untouched when ok).
            // It also owns the heartbeat's app lifetime (start on mount,
            // pause while backgrounded, probe on resume).
            child: ConnectionBanner(
              child:
                  KeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
            ),
          ),
        ),
        // The persistent bottom nav bar is wired per-route in
        // `routing/app_router.dart` (`NavBarShell`), not here — it needs to
        // live *inside* each routed page so it rides the same Navigator
        // Overlay stack as the screen (so an open bottom sheet/dialog covers
        // it too), which a wrapper at this level, above the whole `Router`,
        // could not do. See `widgets/nav_bar_shell.dart`'s doc.
      ),
    );
  }
}
