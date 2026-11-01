import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../env.dart';
import '../legal/biometric_consent_text.dart';
import '../routing/entry.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/biometric_consent.dart';
import '../widgets/ayma_orb.dart';
import 'biometric_consent_screen.dart';
import 'main_shell_screen.dart';
import 'sign_in_screen.dart';
import 'underage_screen.dart';

/// App entry (§11.2). With an [ApiClient] it calls `/bootstrap`, reads the
/// server-derived `session_mode`, and routes to marketing / interview / active
/// (Step 34). Without one — widget tests — it shows the placeholder dev buttons.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.apiClient, this.auth});

  static const path = '/splash';

  final ApiClient? apiClient;
  final FirebaseAuth? auth;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    // Same screen-context entry every other screen sets — kept even though
    // no voice call can start from here, for consistency with the rest of
    // the app's `AppContext` bookkeeping.
    AppContext.instance.set(screen: 'splash');
    if (widget.apiClient != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
    }
  }

  Future<void> _resolve() async {
    // Sign-in is required up front (§3.3) — no anonymous sessions. No user, or
    // an anonymous one left over from an older build, means "go sign in".
    final user = (widget.auth ?? FirebaseAuth.instance).currentUser;
    if (user == null || user.isAnonymous) {
      if (mounted) context.go(SignInScreen.path);
      return;
    }
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
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401 || e.statusCode == 403) {
        // The token is stale / rejected — send them back through sign-in.
        context.go(SignInScreen.path);
        return;
      }
      if (Env.isStaging && Env.apiBaseUrl.contains('.invalid')) {
        // Staging backend is currently a placeholder (.invalid TLD).
        // Route to the app shell so the staging build and UI can be verified.
        debugPrint(
          '[staging] Staging API placeholder unreachable ($e); routing to app shell',
        );
        context.go(MainShellScreen.path);
        return;
      }
      setState(() => _error = 'Could not start ($e).');
    } catch (e) {
      if (!mounted) return;
      if (Env.isStaging && Env.apiBaseUrl.contains('.invalid')) {
        debugPrint(
          '[staging] Staging API placeholder unreachable ($e); routing to app shell',
        );
        context.go(MainShellScreen.path);
        return;
      }
      setState(() => _error = 'Could not start ($e).');
    }
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
        body: Center(
          child: _error == null
              ? const AymaOrb(size: 128, state: AymaOrbState.thinking)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _resolve();
                        },
                        child: const Text('Retry'),
                      ),
                      if (Env.isStaging) ...[
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () => context.go(MainShellScreen.path),
                          child: const Text('Continue to App Shell (Staging)'),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
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
