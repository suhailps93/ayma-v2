import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../legal/biometric_consent_text.dart';
import '../models/boot_config.dart';
import '../routing/entry.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/biometric_consent.dart';
import '../services/deep_link_queue.dart';
import '../services/report_cache.dart';
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
  const SplashScreen({super.key, this.apiClient, this.auth});

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
  /// which can otherwise navigate pre-first-frame down the same cached path.
  static const minSplashDwell = Duration(milliseconds: 800);

  /// How much of [minSplashDwell] is still unelapsed for a splash first
  /// mounted at [shownAtMs] (epoch ms), as of [nowMs]. The startup DAG's
  /// destination routing (N12) — which can reach its own optimistic
  /// navigation long after mount — holds exactly this before navigating.
  static Duration dwellRemaining({required int shownAtMs, required int nowMs}) {
    final remaining = minSplashDwell.inMilliseconds - (nowMs - shownAtMs);
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }

  final ApiClient? apiClient;
  final FirebaseAuth? auth;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
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
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
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
    _watchdog = Timer(SplashScreen.startupDeadline, () {
      if (!mounted) return;
      _deadlineExceeded = true;
      _retryTimer?.cancel();
      setState(() {
        _error = "Couldn't connect. Check your connection and try again.";
        _retrying = false;
      });
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
          final online =
              results.any((r) => r != ConnectivityResult.none);
          if (online && !_inFlight && (_error != null || _retrying)) {
            _attempt = 0;
            _deadlineExceeded = false;
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

  Future<void> _resolve() async {
    if (_inFlight) return;
    _inFlight = true;

    // Sign-in is required up front (§3.3) — no anonymous sessions. No user, or
    // an anonymous one left over from an older build, means "go sign in".
    //
    // The feature tour (§11.2) is NOT gated here any more: it runs after
    // pre-boarding, right before the first chat (the main-shell gate in
    // `MainShellScreen`), guarded by a per-user seen-state — never before
    // sign-in. The Developer panel still previews it on demand.
    final auth = widget.auth ?? FirebaseAuth.instance;
    final user = auth.currentUser;
    final anonymousLanding = user == null || user.isAnonymous;
    if (anonymousLanding) {
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
      router.go(cachedRoute);
      unawaited(_backgroundBootstrap(user.uid, auth, cachedRoute, router));
      return;
    }

    _attempt++;
    try {
      // No short client-side cap here: [ApiClient.bootstrap] already bounds
      // itself (ID-token refresh + POST) with cold-start-tolerant timeouts, so
      // the first call rides through a ~18s+ Cloud Run cold start instead of
      // being force-failed after a couple of seconds (the old 2500ms cap was
      // the "almost every cold open hard-fails" bug). The exponential-backoff
      // retries and the overall [startupDeadline] watchdog still bound startup.
      final result = await widget.apiClient!.bootstrap(sessionId: '');
      if (!mounted) return;
      final route = await _resolveRoute(result);
      if (!mounted) return;
      _cacheEntryRoute(user.uid, result, route);
      DeepLinkQueue.instance.notifyNavigationSettled();
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
  Future<void> _backgroundBootstrap(
      String uid, FirebaseAuth auth, String shownRoute, GoRouter router) async {
    for (var attempt = 0; attempt < SplashScreen.maxStartupAttempts; attempt++) {
      try {
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
      padding: const EdgeInsets.all(24),
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
    final scheme = Theme.of(context).colorScheme;
    return CenteredScroll(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 48, color: scheme.outline),
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
