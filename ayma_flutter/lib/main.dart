import 'dart:async';

import 'package:country_picker/country_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:logging/logging.dart';

import 'build_awareness.dart';
import 'core/app_recovery.dart';
import 'core/dag/boot_trace.dart';
import 'core/dag/launch_intent_resolver.dart';
import 'core/dag/startup_nodes.dart';
import 'core/session_teardown.dart';
import 'routing/app_router.dart';
import 'screens/main_shell_screen.dart';
import 'screens/splash_screen.dart';
import 'services/accent_color_controller.dart';
import 'services/app_context.dart';
import 'services/assist_context.dart';
import 'services/assistant_service.dart';
import 'services/ayma_session.dart';
import 'services/auth_service.dart';
import 'services/auth_session_state.dart';
import 'services/deep_link_queue.dart';
import 'services/install_referrer_service.dart';
import 'services/background_location_service.dart';
import 'services/location_service.dart';
import 'services/permission_coordinator.dart';
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
  BootTrace.start();
  BootTrace.mark('main() entered');
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

  // Resolve the launch intent and tune the DAG's routing edges for it. This
  // runs BEFORE runApp (N8), so it is the ONLY unbounded await on the
  // pre-first-frame path: a slow or hung `getInitialMessage()` / native
  // platform-channel call here would delay the first frame itself. Bound it to
  // the same 1s the DAG's own N6:launch_intent uses so it can never gate the
  // first frame — on timeout the normal icon-launch intent is assumed. This is
  // safe for deep links: N12:destination_routing routes from N6's re-resolved
  // intent (N6 carries the identical 1s bound), not from this value, which only
  // promotes an edge (e.g. a paywall deep link waiting on RevenueCat init).
  BootTrace.mark('LaunchIntentResolver.resolveForStartup() start');
  final intent = await LaunchIntentResolver.resolveForStartup();
  BootTrace.mark('LaunchIntentResolver.resolveForStartup() done ($intent)');
  LaunchIntentResolver.configureDAGForIntent(dag, intent);

  // Run pre-frame DAG to first frame mount (N8:first_frame_mount). N8 depends
  // (transitively) on N7:firebase_core, so once this returns Firebase is
  // guaranteed initialized. The ongoing session listeners below all touch
  // Firebase (PushService → FirebaseMessaging.instance, FirebaseAuth) and MUST
  // NOT be registered before this point: registering them at the top of main()
  // — before the DAG ran N7 — was the P0 boot crash (`PushService()` threw
  // `[core/no-app]`, aborting main() on the splash). See startup_nodes_test.dart
  // for the "run-to-N8 guarantees N7" regression guard.
  BootTrace.mark('dag.run(N8) await start');
  await dag.run(targetNodes: {'N8:first_frame_mount'});
  BootTrace.mark('dag.run(N8) await returned');

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
  unawaited(loadBuildAwareness());
  unawaited(InstallReferrerService.instance.checkInstallReferrer());
  // Ask for OS location permission — but NEVER inside the cold-start window.
  // Firing the system permission dialog while the first frame is still
  // settling (worst on a truly cold fresh-install launch, when ART is still
  // compiling the baseline profile) drops a modal window onto an already
  // stalled main thread — compounding an "input dispatching timed out" ANR —
  // and pauses MainActivity behind the dialog, where a memory-pressured
  // process is silently reaped, so the app vanishes to the launcher with no
  // process and no FATAL (NOTE 239 Leg 4). Gate the ask on the splash's first
  // paint plus a short settle so the dialog only ever appears once the app is
  // idle and interactive. Granting it does NOT enable "Date moments" — the
  // Privacy toggle is the opt-in; this only gets the prompt behind us.
  unawaited(askStartupLocationPermission());

  String? lastKnownUid;
  var sawFirstAuthTick = false;
  FirebaseAuth.instance.authStateChanges().listen((user) {
    if (!sawFirstAuthTick) {
      sawFirstAuthTick = true;
      BootTrace.mark('authStateChanges FIRST tick (user=${user?.uid ?? 'null'})');
    }
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
      // Stop the always-on location watcher when no one is signed in.
      unawaited(BackgroundLocationService.instance.stop());
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
      unawaited(accentColorControllerGlobal.syncRemote(force: isSwitch));
      // (Re)start the always-on location watcher for this account. It only
      // acquires GPS once a Privacy toggle is on AND background permission is
      // granted — otherwise it just watches the (default-off) toggles.
      unawaited(BackgroundLocationService.instance.stop().then(
          (_) => BackgroundLocationService.instance.start()));
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

  // Default-assistant summons (Android Assist API): a long-press Home /
  // assistant gesture ACTIVATES Ayma — it starts a voice session over the
  // foreground app, the way a real default assistant summons. It must NEVER
  // land on the in-app assistant settings screen (founder defect Nov 17). The
  // router's auth redirect still applies, so a signed-out summon goes to
  // sign-in first (voice simply doesn't start until there's a session).
  unawaited(AssistantService.instance.bindSummons(
    onSummon: _activateAymaFromSummon,
  ));
}

/// Activate Ayma for a default-assistant summon: fold the captured foreground
/// screen into [AppContext] so the call opens knowing what the user was looking
/// at, land on the home surface (not the assistant settings screen), and start
/// Ayma's voice session.
void _activateAymaFromSummon(AssistCapture capture) {
  final snap = capture.snapshot;
  if (snap.hasScreenContent) {
    AppContext.instance.set(
      screen: 'external_app',
      subjectName: snap.friendlyAppName,
      note: snap.foregroundPackage,
      detail: snap.detailSummary(),
    );
  }
  navigateToRoute(MainShellScreen.path);
  // Enable voice mode + activate Ayma. start() is idempotent (a no-op if a
  // call is already live) and self-contained; never let a start failure (e.g.
  // a summon before sign-in) throw out of this fire-and-forget path.
  unawaited(AymaSession.instance.voice.start().catchError((Object _) {}));
}

/// Settle after the splash's first paint before the startup
/// location-permission prompt, so the OS dialog never collides with the
/// cold-start stall window (NOTE 239 Leg 4). Overridable from tests.
@visibleForTesting
Duration startupLocationAskSettle = const Duration(seconds: 3);

/// Settle after an empty / cancelled startup location prompt before retrying,
/// giving route transitions and competing startup dialogs time to complete so
/// the retry lands when the app is fully idle and interactive (NOTE 242 Leg 1).
/// Overridable from tests.
@visibleForTesting
Duration startupLocationAskRetrySettle = const Duration(seconds: 2);

/// First-paint gate for the startup location ask: the splash's presented-first
/// -frame signal, bounded so a wedged frame pipeline never starves the prompt
/// forever (it just proceeds).
Future<void> _defaultWaitFirstPaint() => SplashFirstPaint.done
    .timeout(const Duration(seconds: 25), onTimeout: () {});

/// Ask for OS location permission at startup, but only once the first frame is
/// presented and the app has settled — never inside the cold-start window,
/// where a modal permission dialog compounds the input-dispatch ANR and leaves
/// the paused process open to an OS reap (NOTE 239 Leg 4). If the initial ask
/// returns empty or cancelled (e.g. races a route transition or competing
/// dialog on a fresh-install signed-out path — NOTE 242 Leg 1, NOTE 244), it
/// retries once competing permission dialogs have dismissed and the app is fully
/// idle and interactive, provided the permission is not denied forever.
/// The ask itself still never throws (see [LocationService.ensurePermission]).
@visibleForTesting
Future<void> askStartupLocationPermission({
  Future<bool> Function()? ask,
  Future<void> Function()? waitFirstPaint,
  Future<void> Function(Duration)? settle,
  Future<LocationPermission> Function()? checkPermission,
  int maxRetries = 1,
  Future<void> Function()? waitForIdle,
  bool Function()? isCompetingDialogShowing,
}) async {
  await (waitFirstPaint ?? _defaultWaitFirstPaint)();
  await (settle ?? (d) => Future<void>.delayed(d))(startupLocationAskSettle);

  BootTrace.mark('askStartupLocationPermission: prompt start');
  final doAsk = ask ?? const LocationService().ensurePermission;
  final check = checkPermission ?? const LocationService().checkPermission;
  final checkCompeting = isCompetingDialogShowing ??
      () => PermissionCoordinator.instance.isCompetingDialogShowing;
  final waitIdle =
      waitForIdle ?? () => PermissionCoordinator.instance.waitForIdle();

  var granted = await doAsk();
  BootTrace.mark('askStartupLocationPermission: result granted=$granted');
  if (granted) return;

  // The first request returned empty / still denied (e.g. Android dropped the
  // request with empty grantResults because a route transition or competing
  // startup dialog was in flight — Scout NOTE 242, NOTE 244).
  // If permission is still denied and NOT deniedForever, serialize against
  // competing permission dialogs (wait until no other system permission
  // dialog is showing), settle, and retry.
  for (var i = 0; i < maxRetries; i++) {
    final status = await check();
    if (status != LocationPermission.denied) {
      break;
    }
    if (isCompetingDialogShowing != null) {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (isCompetingDialogShowing() && DateTime.now().isBefore(deadline)) {
        await waitIdle();
      }
    } else if (waitForIdle != null) {
      await waitForIdle();
    } else {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (checkCompeting() && DateTime.now().isBefore(deadline)) {
        await waitIdle();
      }
    }
    await (settle ?? (d) => Future<void>.delayed(d))(startupLocationAskRetrySettle);
    granted = await doAsk();
    if (granted) break;
  }
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
