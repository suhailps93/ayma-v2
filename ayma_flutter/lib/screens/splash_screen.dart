import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../legal/biometric_consent_text.dart';
import '../routing/entry.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/biometric_consent.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/overflow_guards.dart';
import 'biometric_consent_screen.dart';
import 'sign_in_screen.dart';
import 'underage_screen.dart';

/// App entry (§11.2). With an [ApiClient] it calls `/bootstrap`, reads the
/// server-derived `session_mode`, and routes to marketing / interview / active
/// (Step 34). Without one — widget tests — it shows the placeholder dev buttons.
///
/// Startup is made resilient to a flaky network (the founder-reported "splash
/// hangs forever" bug): `/bootstrap` has explicit timeouts in [ApiClient], a
/// single transient failure is retried automatically with backoff, a restored
/// connection retries immediately, and once the quick retries are spent a
/// branded "Couldn't connect — Retry" state replaces the bare spinner. Only a
/// genuine auth failure (401/403) routes to sign-in; a network failure never
/// bounces a signed-in user out of their session.
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
  /// affordance by now rather than an endless orb (§11.2). Public so the test
  /// can assert the exact watchdog behaviour.
  static const startupDeadline = Duration(seconds: 20);

  final ApiClient? apiClient;
  final FirebaseAuth? auth;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  /// Increasing gaps between auto-retries (index = retry number − 1). Kept
  /// short so recovery is quick but a stuck device never hammers the network.
  static const _backoff = [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 6),
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

  /// The belt-and-braces guarantee that startup can never hang on the orb: if
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
    final user = (widget.auth ?? FirebaseAuth.instance).currentUser;
    if (user == null || user.isAnonymous) {
      _inFlight = false;
      if (mounted) context.go(SignInScreen.path);
      return;
    }

    _attempt++;
    try {
      final result = await widget.apiClient!.bootstrap(sessionId: '');
      if (!mounted) return;
      var consentRequired = result.biometricConsentRequired;
      if (consentRequired &&
          !result.ageBlocked &&
          !result.recoveryRequired &&
          await _recordPendingConsent()) {
        consentRequired = false;
      }
      if (!mounted) return;
      if (!consentRequired) BiometricConsentState.instance.clear();
      context.go(
        result.ageBlocked
            ? UnderageScreen.path
            : result.recoveryRequired
                ? '/recover'
                : consentRequired
                    // An account with no consent record and nothing ticked
                    // on this device: the one-time consent screen.
                    ? BiometricConsentScreen.path
                    : entryRouteFor(result.sessionMode),
      );
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
      // SocketException / TimeoutException / Firebase network errors surface
      // here — all transient plumbing failures, so retry rather than giving up.
      if (!mounted) return;
      _onTransientFailure(
        "Couldn't connect. Check your connection and try again.",
        retryable: true,
      );
    } finally {
      _inFlight = false;
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

/// The splash spinner: the branded orb, with a quiet "Reconnecting…" line
/// while an auto-retry is pending so the user knows it's still working.
class SplashLoading extends StatelessWidget {
  const SplashLoading({super.key, this.reconnecting = false});

  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    return CenteredScroll(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AymaOrb(size: 128, state: AymaOrbState.thinking),
          if (reconnecting) ...[
            const SizedBox(height: 20),
            Text(
              'Reconnecting…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant,
                  ),
            ),
          ],
        ],
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
