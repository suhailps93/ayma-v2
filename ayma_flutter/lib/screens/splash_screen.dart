import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../routing/entry.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../widgets/ayma_orb.dart';
import 'sign_in_screen.dart';

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
    // A cold start lands here already signed in (bootstrap is still
    // in-flight) — auth alone doesn't suppress GlobalAymaLauncher for that
    // window, so it needs a real screen-context entry, same as every other
    // screen (§ founder report: the floating button showing over the
    // loading orb).
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
      context.go(
        result.recoveryRequired ? '/recover' : entryRouteFor(result.sessionMode),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401 || e.statusCode == 403) {
        // The token is stale / rejected — send them back through sign-in.
        context.go(SignInScreen.path);
        return;
      }
      setState(() => _error = 'Could not start ($e).');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not start ($e).');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.apiClient != null) {
      return Scaffold(
        body: Center(
          child: _error == null
              ? const AymaOrb(size: 128, state: AymaOrbState.thinking)
              : Padding(
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
