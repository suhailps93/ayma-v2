import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/dag/boot_trace.dart';
import '../core/firebase_config_guard.dart';
import '../legal/biometric_consent_text.dart';
import '../models/boot_config.dart';
import '../routing/entry.dart';
import '../services/accent_color_controller.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/auth_service.dart';
import '../services/biometric_consent.dart';
import '../services/deep_link_queue.dart';
import '../services/report_cache.dart';
import '../theme.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/overflow_guards.dart';
import 'biometric_consent_screen.dart';
import 'main_shell_screen.dart';
import 'sign_in_screen.dart';
import 'underage_screen.dart';

/// App entry (§11.2). With an [ApiClient] it calls `/bootstrap`, reads the
/// server-derived `session_mode`, and routes to marketing / interview / active
/// (Step 34). Without one — widget tests — it shows the placeholder dev buttons.
///
/// Startup PREFERS LOADING OVER FAILING (founder-reported "almost every cold
/// open hard-fails with Couldn't connect"): `ayma-api` scales to zero, so the
/// first request after idle pays a Cloud Run cold start (~18s+). On mount the
/// splash fires a lightweight unauthenticated `GET /health` wake-ping to start
/// that warm-up immediately, then runs `/bootstrap` under [ApiClient]'s own
/// cold-start-tolerant budget (ID-token refresh + POST, up to ~27s) — it is
/// NOT capped to a short client timeout any more, which is exactly what used
/// to turn a slow cold start into an instant hard failure. A transient failure
/// is retried automatically with exponential backoff (1s, 2s, 4s, 8s) inside a
/// generous overall budget ([startupDeadline]) that comfortably covers a cold
/// start plus a retry; a restored connection retries immediately. Only once
/// that whole budget is spent does a branded "Couldn't connect — Retry" state
/// replace the loader. Only a genuine auth failure (401/403) routes to sign-in; a
/// network failure never bounces a signed-in user out of their session.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    this.apiClient,
    this.auth,
    this.accentController,
    this.authService,
  });

  static const path = '/splash';

  /// One first try plus three auto-retries before startup stops and shows the
  /// manual Retry affordance. Public so tests can drive exactly that many
  /// transient failures.
  static const maxStartupAttempts = 4;

  /// Hard overall deadline for a startup cycle. However the per-call timeouts
  /// and the backoff loop fall out (or are defeated — an await that never
  /// completes, a plugin that never reports), the splash MUST show the Retry
  /// affordance by now rather than an endless loader (§11.2). Public so the test
  /// can assert the exact watchdog behaviour.
  ///
  /// Sized to comfortably cover a Cloud Run cold start (~18s+) plus an
  /// automatic retry, so a genuinely slow-but-reachable backend recovers into
  /// the app rather than tripping this ceiling. It is a last-resort guard, not
  /// the primary failure path: a reachable backend lands long before it fires.
  static const startupDeadline = Duration(seconds: 45);

  /// Minimum time the cold-start splash stays up — with the wing loader and
  /// the "Waking up Ayma…" line — before an optimistic cached-route
  /// navigation may leave it. Without this the cached route lands before the
  /// splash has been visible for any real time (loader retest, Nov 2026: the
  /// wake line NEVER surfaced in 3 cold starts). Not faked work: the wake-ping
  /// has just fired and the background bootstrap is starting/running while
  /// this holds. Shared with the startup DAG's destination routing (N12),
  /// which holds this AFTER the splash's first frame is presented —
  /// framework-time signals (runApp-call time, the first post-frame
  /// callback) let the navigation land before the splash is ever displayed
  /// (loader fix round 3, Nov 2026).
  static const minSplashDwell = Duration(milliseconds: 800);

  final ApiClient? apiClient;
  final FirebaseAuth? auth;
  final AccentColorController? accentController;
  final AuthService? authService;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// Process-lifetime signal: the cold-start splash's first frame has been
/// PRESENTED (rasterized by the engine — within ~a vsync of display), not
/// merely built by the framework. Marked once; the startup DAG's destination
/// routing (N12) awaits [done] before its optimistic cached-route navigation
/// so that navigation can only ever replace a displayed splash, never
/// pre-empt it (loader fix round 3: the round-2 post-frame signal is
/// framework-time, and presentation can lag past the dwell on a slow
/// device — Scout 2295: the wake line displayed only 1/3 cold starts).
/// Sticky: a caller arriving after the presentation gets an
/// already-completed future and proceeds immediately.
abstract final class SplashFirstPaint {
  static Completer<void>? _painted;
  static Future<void> Function()? _waitForPresentationForTest;

  /// Completes when the splash paints its first frame.
  static Future<void> get done {
    final completer = _painted ??= Completer<void>();
    return completer.future;
  }

  /// Called once, after the splash's first frame is presented (see
  /// [_SplashScreenState] presentation gate). Idempotent.
  static void markPainted() {
    final completer = _painted ??= Completer<void>();
    if (!completer.isCompleted) completer.complete();
  }

  /// Presentation-time wait (loader fix round 3, Nov 2026): completes once
  /// the engine has rasterized the first frame — within ~a vsync of it being
  /// displayed — so a dwell measured from here covers real visible time.
  /// Bounded: a wedged frame pipeline degrades to proceeding rather than
  /// hanging startup (N12 carries its own failsafe on [done] too).
  static Future<void> waitForPresentation() async {
    final testWait = _waitForPresentationForTest;
    if (testWait != null) {
      await testWait();
      return;
    }
    try {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized
          .timeout(const Duration(milliseconds: 600));
    } catch (_) {
      // No rasterization signal in time: proceed rather than hang startup.
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _painted = null;
    // The engine never reports rasterization under flutter_test, so tests
    // treat the first built frame as presented unless they gate it via
    // [setWaitForPresentationForTest] (the slow-presentation test does).
    _waitForPresentationForTest = () async {};
  }

  /// Overrides [waitForPresentation] for one test: the stand-in for the
  /// engine's rasterization signal, which widget tests cannot observe.
  @visibleForTesting
  static void setWaitForPresentationForTest(Future<void> Function() wait) {
    _waitForPresentationForTest = wait;
  }
}

/// The absolute wall-clock ceiling for the WHOLE startup, held at process
/// scope so it survives the splash being torn down and rebuilt.
///
/// NOTE 273 made the deadline survive the watchdog being *re-armed* within one
/// splash State (flapping connectivity). NOTE 279 defect 3: on the PROFILE
/// deep-link / fresh-install path the splash can be re-MOUNTED instead — the
/// router gate bounces `/signin`→`/splash` while the session is still restoring,
/// building a fresh `_SplashScreenState` each time — and a per-State deadline
/// reset to a new 45s on every mount, so the ceiling never fired and "Waking up
/// Ayma…" hung indefinitely. A process-global deadline is shared across those
/// re-mounts: once it passes, every freshly-built splash surfaces the manual
/// Retry at once instead of churning. A deliberate Retry clears it for a fresh
/// budget (that is the only reset).
abstract final class StartupDeadline {
  static DateTime? _at;
  static bool _tripped = false;

  /// The ceiling, fixed the first time it is read in a boot.
  static DateTime ensure() =>
      _at ??= DateTime.now().add(SplashScreen.startupDeadline);

  /// Time left to the ceiling (negative once passed).
  static Duration get remaining => ensure().difference(DateTime.now());

  /// True once the ceiling has passed or been tripped — a re-mounted splash
  /// reads this to show Retry immediately rather than resolve again.
  static bool get exceeded => _tripped || remaining <= Duration.zero;

  static void markTripped() => _tripped = true;

  /// A deliberate manual Retry earns a fresh absolute window.
  static void reset() {
    _at = null;
    _tripped = false;
  }

  @visibleForTesting
  static void resetForTest() => reset();
}

class _SplashScreenState extends State<SplashScreen> {
  /// Exponential gaps between auto-retries (index = retry number − 1): 1s, 2s,
  /// 4s, 8s (capped). Quick enough that a transient blip recovers fast, backed
  /// off enough that a stuck device never hammers the network.
  static const _backoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  String? _error;
  bool _retrying = false;
  bool _inFlight = false;
  bool _deadlineExceeded = false;
  int _attempt = 0;
  Timer? _retryTimer;
  Timer? _watchdog;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// Last known connectivity, so only a genuine offline→online TRANSITION
  /// triggers an early retry — not the duplicate "still online" events a cold
  /// boot emits, which used to reset the entire startup budget each time.
  bool _online = true;

  @override
  void initState() {
    super.initState();
    // Same screen-context entry every other screen sets — kept even though
    // no voice call can start from here, for consistency with the rest of
    // the app's `AppContext` bookkeeping.
    AppContext.instance.set(screen: 'splash');
    if (widget.apiClient != null) {
      // Wake a scaled-to-zero backend ASAP so the real `/bootstrap` below is
      // more likely to hit an already-warm Cloud Run instance. Fire-and-forget
      // and unauthenticated (`GET /health`); failures are swallowed inside
      // [ApiClient.wakeUp] and never affect the bootstrap sequence.
      unawaited(widget.apiClient!.wakeUp());
      _watchConnectivity();
      _startWatchdog();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The first frame containing the splash was just built — but built
        // is not displayed: wait for presentation before marking painted and
        // resolving, so every dwell starts with the wake line on screen.
        unawaited(_onFirstFrameBuilt());
      });
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _watchdog?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  /// The belt-and-braces guarantee that startup can never hang on the loader: if
  /// nothing has navigated away from the splash within [SplashScreen
  /// .startupDeadline], force the branded Retry state. A successful bootstrap
  /// (or a route to sign-in) disposes this screen, which cancels the timer, so
  /// this only ever fires when the app is genuinely stuck.
  void _startWatchdog() {
    _watchdog?.cancel();
    // Absolute ceiling: fixed the first time it is armed and only re-armed for
    // the time REMAINING to it, so a flapping connection can never push startup
    // past it (NOTE 273) — and held at PROCESS scope so a splash re-mount can't
    // reset it either (NOTE 279 defect 3). A manual Retry clears it for a fresh
    // budget.
    final remaining = StartupDeadline.remaining;
    // Clamp to zero rather than firing synchronously: _startWatchdog runs inside
    // initState on a re-mount whose shared deadline has already passed, and
    // _onDeadlineExceeded calls setState — a zero-delay Timer defers it past the
    // first build so it is legal (NOTE 279 defect 3).
    _watchdog = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      _onDeadlineExceeded,
    );
  }

  void _onDeadlineExceeded() {
    StartupDeadline.markTripped();
    if (!mounted) return;
    _deadlineExceeded = true;
    _retryTimer?.cancel();
    setState(() {
      _error = "Couldn't connect. Check your connection and try again.";
      _retrying = false;
    });
  }

  /// A restored connection while we're stalled (showing the error state or
  /// waiting out a backoff) retries at once with a fresh budget, so the user
  /// doesn't have to sit through the remaining delay or tap Retry. Guarded:
  /// on a host without the plugin (unit tests) the backoff loop and the
  /// manual Retry still recover startup.
  void _watchConnectivity() {
    try {
      _connSub = Connectivity().onConnectivityChanged.listen(
        (results) {
          final online = results.any((r) => r != ConnectivityResult.none);
          final wasOffline = !_online;
          _online = online;
          // ONLY a real offline→online transition retries early. The duplicate
          // "still online" events a cold boot emits must not reset the budget
          // (Scout NOTE 273), and once the absolute watchdog has surfaced the
          // manual Retry we leave the next attempt to the user — never silently
          // resume the invisible loop by clearing _deadlineExceeded.
          if (online &&
              wasOffline &&
              !_deadlineExceeded &&
              !_inFlight &&
              (_error != null || _retrying)) {
            _attempt = 0;
            _retryTimer?.cancel();
            _startWatchdog();
            _resolve();
          }
        },
        onError: (_) {},
      );
    } catch (_) {
      // connectivity_plus unavailable here — degrade to backoff + manual Retry.
    }
  }

  /// Presentation-time gate (loader fix round 3, Nov 2026): the round-2 gate
  /// marked the splash painted in its first post-frame callback
  /// (framework-time), but on a slow device the frame's presentation can lag
  /// past the dwell — so a navigation timed from the build lands before the
  /// splash is ever displayed (Scout 2295: white straight to chat-load, 2/3).
  /// Holding for the engine's rasterization signal first means N12's dwell
  /// and the splash's own dwell in [_resolve] both start with the wake line
  /// actually on screen. Still real work in flight, never a faked delay: the
  /// wake-ping fired in [initState] and the background bootstrap runs while
  /// the dwells hold.
  Future<void> _onFirstFrameBuilt() async {
    BootTrace.mark('splash first-frame built (awaiting presentation)');
    await SplashFirstPaint.waitForPresentation();
    if (!mounted) return;
    BootTrace.mark('splash first-frame PRESENTED (markPainted)');
    SplashFirstPaint.markPainted();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    if (_inFlight) return;
    // The absolute startup ceiling has already passed (in THIS boot, possibly on
    // an earlier splash mount): don't resolve-and-navigate again — that is the
    // very churn that keeps re-mounting the splash. Surface the manual Retry and
    // stop, breaking the /splash⇄/signin loop (NOTE 279 defect 3).
    if (StartupDeadline.exceeded) {
      _onDeadlineExceeded();
      return;
    }
    _inFlight = true;
    BootTrace.mark('splash _resolve() enter');

    // A mis-built APK (native Firebase project ≠ Dart firebase_options project)
    // mints tokens for the wrong project, so sign-in succeeds but every authed
    // call 401s and the user is bounced through sign-in forever. Surface an
    // honest, non-retryable diagnostic instead — before the cached-route fast
    // path or any bootstrap — rather than looping silently (Scout NOTE 263).
    final configError = FirebaseConfigGuard.instance.mismatch;
    if (configError != null) {
      _inFlight = false;
      _onTransientFailure(configError, retryable: false);
      return;
    }

    // Sign-in is required up front (§3.3) — no anonymous sessions. No user, or
    // an anonymous one left over from an older build, means "go sign in".
    //
    // The feature tour (§11.2) is NOT gated here any more: it runs after
    // pre-boarding, right before the first chat (the main-shell gate in
    // `MainShellScreen`), guarded by a per-user seen-state — never before
    // sign-in. The Developer panel still previews it on demand.
    final auth = widget.auth ?? FirebaseAuth.instance;
    var user = auth.currentUser;
    if (user == null && (widget.auth == null || widget.authService != null)) {
      BootTrace.mark('splash _resolve: currentUser is null, awaiting ensureAuthReady');
      try {
        final authSvc = widget.authService ?? AuthService.instance;
        user = await authSvc
            .ensureAuthReady()
            .timeout(const Duration(seconds: 2), onTimeout: () => auth.currentUser);
      } catch (_) {
        user = auth.currentUser;
      }
    }
    final anonymousLanding = user == null || user.isAnonymous;
    BootTrace.mark('splash _resolve: currentUser=${user?.uid ?? 'null'} '
        'anon=$anonymousLanding');
    if (anonymousLanding) {
      // A returning signed-in user whose KeyStore/Keychain session is still
      // being restored can leave `currentUser` null past the 2s auth wait
      // above. Bouncing them to /signin forces a needless re-login — the exact
      // failure the deep-link hard invariant was written to prevent, on the one
      // path it does not cover (startup audit §3.3). If this device holds a
      // cached BootConfig from a prior signed-in session, paint that last-known
      // route optimistically instead; the recovery helper then waits a little
      // longer for auth to finish and runs the background bootstrap (which
      // corrects the route, or routes to /signin honestly if the session is
      // genuinely gone / the token is rejected). A clean sign-out wipes the
      // cache, so a deliberately signed-out user has no config here and still
      // lands on sign-in.
      final recovered = await ReportCache.instance.readAnyBootConfig();
      if (recovered != null && mounted) {
        await Future<void>.delayed(SplashScreen.minSplashDwell);
        if (!mounted) return;
        _inFlight = false;
        final router = GoRouter.of(context);
        DeepLinkQueue.instance.notifyNavigationSettled();
        BootTrace.mark('splash NAVIGATE to recovered cached '
            '${recovered.entryRoute} (auth still restoring)');
        router.go(recovered.entryRoute);
        unawaited(_recoverAuthThenBootstrap(recovered, auth, router));
        return;
      }
      _inFlight = false;
      if (mounted) context.go(SignInScreen.path);
      return;
    }

    // Optimistic cold start (founder 2026-10-28: "show the cached page and
    // bootstrap in the backend"). When we have a cached entry route for THIS
    // signed-in uid, paint the last-known UI immediately and move the full
    // bootstrap to the background — it corrects the route if the session has
    // actually changed.
    final cachedConfig = await ReportCache.instance.readBootConfig(user.uid);
    final cachedRoute = cachedConfig?.entryRoute ??
        await ReportCache.instance.readBootRoute(user.uid);
    BootTrace.mark('splash _resolve: cachedRoute=$cachedRoute');
    if ((cachedRoute == null || cachedRoute.isEmpty) && mounted) {
      final router = GoRouter.of(context);
      if (await _tryFirestoreCacheFallback(user.uid)) {
        BootTrace.mark('splash _resolve: navigated via firestore cache fallback');
        unawaited(_backgroundBootstrap(user.uid, auth, MainShellScreen.path, router));
        return;
      }
    }
    if (cachedRoute != null && cachedRoute.isNotEmpty && mounted) {
      // Hold the splash for the minimum dwell so the wake line is actually
      // visible: without this the navigation below lands before the splash
      // has been up for any real time. A fixed hold, deliberately not
      // elapsed-subtracted — this branch runs within milliseconds of mount,
      // and a real-clock subtraction would be timing-flaky under test.
      // Still never waits on bootstrap.
      await Future<void>.delayed(SplashScreen.minSplashDwell);
      if (!mounted) return;
      _inFlight = false;
      final router = GoRouter.of(context);
      DeepLinkQueue.instance.notifyNavigationSettled();
      BootTrace.mark('splash NAVIGATE to cached $cachedRoute');
      router.go(cachedRoute);
      unawaited(_backgroundBootstrap(user.uid, auth, cachedRoute, router));
      return;
    }

    _attempt++;
    try {
      BootTrace.mark('splash _resolve: foreground bootstrap enter');
      unawaited((widget.accentController ?? accentColorControllerGlobal)
          .syncRemoteIfMissing());
      final result = await widget.apiClient!.bootstrap(sessionId: '');
      if (!mounted) return;
      final route = await _resolveRoute(result);
      if (!mounted) return;
      _cacheEntryRoute(user.uid, result, route);
      DeepLinkQueue.instance.notifyNavigationSettled();
      BootTrace.mark('splash NAVIGATE to $route');
      context.go(route);
    } on AuthSessionException catch (e) {
      // The restored auth session is unusable (keystore / decrypt failure after
      // an Auto Backup restore, or a rejected / disabled user) — NOT a network
      // blip, so retrying can only loop forever. Clear the broken session and
      // send the user through sign-in, which overwrites the bad persisted auth.
      debugPrint('splash: broken auth session, signing out — ${e.message}');
      try {
        await (widget.auth ?? FirebaseAuth.instance).signOut();
      } catch (_) {
        // Even if sign-out itself fails, still route to sign-in: the sign-in
        // flow re-authenticates and replaces the unreadable persisted session.
      }
      if (!mounted) return;
      context.go(SignInScreen.path);
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401 || e.statusCode == 403) {
        // The token is genuinely stale / rejected — send them back through
        // sign-in. A network failure (no statusCode, or a 5xx) is NOT this:
        // it must never lose a signed-in user's session, so it retries.
        context.go(SignInScreen.path);
        return;
      }
      _onTransientFailure(
        "Couldn't connect. Check your connection and try again.",
        retryable: _isRetryable(e),
      );
    } catch (e) {
      // Degraded network / timeout: try local Firestore cache heuristic before
      // surfacing the retry state (§5.4).
      if (await _tryFirestoreCacheFallback(user.uid)) {
        return;
      }
      if (!mounted) return;
      _onTransientFailure(
        "Couldn't connect. Check your connection and try again.",
        retryable: true,
      );
    } finally {
      _inFlight = false;
    }
  }

  Future<bool> _tryFirestoreCacheFallback(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('profile')
          .doc('main')
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 300));
      final data = snap.data();
      final hasCompleted = snap.exists &&
          ((data?['name'] != null && data?['birthdate'] != null) ||
              data?['onboarding_completed'] == true);
      if (hasCompleted && mounted) {
        DeepLinkQueue.instance.notifyNavigationSettled();
        context.go(MainShellScreen.path);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Turns a successful [BootstrapResult] into the route to land on, applying
  /// the biometric-consent side-effects exactly as the original inline logic
  /// did. Shared by the blocking resolve and the optimistic background
  /// bootstrap so both compute the destination identically. Uses no
  /// [BuildContext], so it is safe to call after the splash has been disposed.
  Future<String> _resolveRoute(BootstrapResult result) async {
    // Keep the global recovery gate in sync with the server's verdict so the
    // router (which may run before or after this) never lets a soft-deleted
    // account reach the app, and a recovered one is no longer held back (B9).
    if (result.recoveryRequired) {
      RecoveryRequiredState.instance.markRequired();
    } else {
      RecoveryRequiredState.instance.clear();
    }
    var consentRequired = result.biometricConsentRequired;
    if (consentRequired &&
        !result.ageBlocked &&
        !result.recoveryRequired &&
        await _recordPendingConsent()) {
      consentRequired = false;
    }
    if (!consentRequired) BiometricConsentState.instance.clear();
    return result.ageBlocked
        ? UnderageScreen.path
        : result.recoveryRequired
            ? '/recover'
            : consentRequired
                // An account with no consent record and nothing ticked
                // on this device: the one-time consent screen.
                ? BiometricConsentScreen.path
                : entryRouteFor(result.sessionMode);
  }

  /// Remembers [route] for [uid]'s next cold start — but ONLY when it is the
  /// plain entry route (no exceptional gate fired). Caching, say, the consent
  /// or underage gate and replaying it optimistically could flash a state that
  /// no longer applies; the entry routes are stable and safe to show first.
  void _cacheEntryRoute(String uid, BootstrapResult result, String route) {
    if (route == entryRouteFor(result.sessionMode)) {
      unawaited(ReportCache.instance.writeBootRoute(uid, route));
      final config = BootConfig(
        uid: uid,
        sessionMode: result.sessionMode,
        entryRoute: route,
        cachedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
        biometricConsentRequiredHint: result.biometricConsentRequired,
        ageBlockedHint: result.ageBlocked,
        recoveryRequiredHint: result.recoveryRequired,
      );
      unawaited(ReportCache.instance.writeBootConfig(uid, config));
    }
  }

  /// Runs the full bootstrap after the optimistic cached UI is already on
  /// screen, then corrects the route if the real session differs. Independent
  /// of this (now-disposed) widget's lifecycle, so it navigates via the global
  /// [appRouter], never [context]. Keeps every startup-hardening rule: a
  /// network blip NEVER signs the user out — it retries with the same backoff
  /// and leaves the cached UI up; only a genuine auth rejection (401/403) or an
  /// unusable restored session routes to sign-in.
  /// Companion to the §3.3 optimistic recovery above: we painted a returning
  /// user's cached route despite a null `currentUser` (slow session restore),
  /// so give auth a longer window to finish before the authed background
  /// bootstrap — otherwise it would 401 immediately and bounce the user to
  /// sign-in, defeating the recovery. If auth never restores, correct to
  /// sign-in honestly.
  Future<void> _recoverAuthThenBootstrap(
      BootConfig recovered, FirebaseAuth auth, GoRouter router) async {
    var user = auth.currentUser;
    if (user == null) {
      try {
        user = await (widget.authService ?? AuthService.instance)
            .ensureAuthReady()
            .timeout(const Duration(seconds: 8), onTimeout: () => auth.currentUser);
      } catch (_) {
        user = auth.currentUser;
      }
    }
    if (user == null || user.isAnonymous) {
      BootTrace.mark('splash recovery: auth never restored, correcting to signin');
      // Use the captured router (not `context`): the splash has already
      // navigated to the cached route, so its State is disposed and `mounted`
      // is false — but the router outlives it, exactly as _backgroundBootstrap
      // relies on. Guarding this on `mounted` would strand a tokenless user on
      // the optimistic shell.
      router.go(SignInScreen.path);
      return;
    }
    await _backgroundBootstrap(user.uid, auth, recovered.entryRoute, router);
  }

  Future<void> _backgroundBootstrap(
      String uid, FirebaseAuth auth, String shownRoute, GoRouter router) async {
    for (var attempt = 0; attempt < SplashScreen.maxStartupAttempts; attempt++) {
      try {
        unawaited((widget.accentController ?? accentColorControllerGlobal)
            .syncRemoteIfMissing());
        final result = await widget.apiClient!.bootstrap(sessionId: '');
        final route = await _resolveRoute(result);
        _cacheEntryRoute(uid, result, route);
        if (route != shownRoute) router.go(route);
        return;
      } on AuthSessionException catch (e) {
        debugPrint('splash(bg): broken auth session, signing out — ${e.message}');
        try {
          await auth.signOut();
        } catch (_) {
          // Sign-in re-authenticates and overwrites the bad persisted session.
        }
        await ReportCache.instance.clearForSignOut();
        router.go(SignInScreen.path);
        return;
      } on ApiException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 403) {
          // Token genuinely rejected: correct the optimistic UI to sign-in.
          router.go(SignInScreen.path);
          return;
        }
        if (!_isRetryable(e) ||
            attempt == SplashScreen.maxStartupAttempts - 1) {
          return; // Give up quietly; the cached UI stays, next launch retries.
        }
        await Future<void>.delayed(
            _backoff[attempt.clamp(0, _backoff.length - 1)]);
      } catch (_) {
        if (attempt == SplashScreen.maxStartupAttempts - 1) return;
        await Future<void>.delayed(
            _backoff[attempt.clamp(0, _backoff.length - 1)]);
      }
    }
  }

  /// A network-class failure is anything without a definite client-rejected
  /// status: no status at all (timeout / DNS / socket) or a server 5xx.
  bool _isRetryable(ApiException e) =>
      e.statusCode == null || e.statusCode! >= 500;

  void _onTransientFailure(String message, {required bool retryable}) {
    _retryTimer?.cancel();
    if (_deadlineExceeded) {
      // The overall watchdog already surfaced the Retry state; a late-
      // completing attempt must not flip it back to a reconnecting spinner.
      setState(() {
        _error = message;
        _retrying = false;
      });
      return;
    }
    if (retryable && _attempt < SplashScreen.maxStartupAttempts) {
      final delay = _backoff[(_attempt - 1).clamp(0, _backoff.length - 1)];
      setState(() {
        _error = null;
        _retrying = true;
      });
      _retryTimer = Timer(delay, () {
        if (mounted) _resolve();
      });
    } else {
      setState(() {
        _error = message;
        _retrying = false;
      });
    }
  }

  void _retryNow() {
    _retryTimer?.cancel();
    _attempt = 0;
    _deadlineExceeded = false;
    // A deliberate tap earns a fresh absolute window (the connectivity path
    // never clears this; only the user does). Process-global so the reset holds
    // across any subsequent splash re-mount (NOTE 279 defect 3).
    StartupDeadline.reset();
    _startWatchdog();
    setState(() {
      _error = null;
      _retrying = true;
    });
    _resolve();
  }

  /// The face-recognition consent ticked on the sign-in page is recorded
  /// here, right after the first successful sign-in. True once the server has
  /// stored it; on failure it stays pending on the device for the next launch.
  Future<bool> _recordPendingConsent() async {
    final version = await PendingBiometricConsent.read();
    if (version != kBiometricConsentVersion) return false;
    try {
      await widget.apiClient!.acceptBiometricConsent(
        region: deviceRegionCode(),
      );
    } catch (e) {
      debugPrint('recording the sign-in biometric consent failed: $e');
      return false;
    }
    await PendingBiometricConsent.clear();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.apiClient != null) {
      return Scaffold(
        body: _error == null
            ? SplashLoading(reconnecting: _retrying)
            : SplashErrorView(message: _error!, onRetry: _retryNow),
      );
    }

    // Placeholder dev navigation (no ApiClient injected).
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Splash (placeholder)'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/preboarding'),
              child: const Text('Go to Preboarding'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text('Go to Main shell'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => context.go('/link'),
              child: const Text('Go to Credential picker'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The splash spinner: the shared wing loader. Stage 0 ("Waking up Ayma…")
/// covers the `GET /health` wake-ping plus the first `/bootstrap` attempt;
/// stage 1 ("Reconnecting…") shows while an auto-retry is pending or in
/// flight — wired to the existing [_SplashScreenState._retrying] flag, so the
/// line always names what startup is actually doing.
class SplashLoading extends StatelessWidget {
  const SplashLoading({super.key, this.reconnecting = false});

  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    return CenteredScroll(
      padding: const EdgeInsets.all(20),
      child: AymaWingLoader(
        size: 96,
        lines: AymaLoaderLines.startup,
        stage: reconnecting ? 1 : 0,
      ),
    );
  }
}

/// Shown once the quick auto-retries are spent: a clear, on-brand "couldn't
/// connect" message with a Retry button, in place of an endless blank spinner.
class SplashErrorView extends StatelessWidget {
  const SplashErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return CenteredScroll(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 48, color: ac.fgDim),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
