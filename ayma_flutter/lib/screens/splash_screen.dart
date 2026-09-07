import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../routing/entry.dart';
import '../services/api_client.dart';

/// App entry (§11.2). With an [ApiClient] it calls `/bootstrap`, reads the
/// server-derived `session_mode`, and routes to marketing / interview / active
/// (Step 34). Without one — widget tests — it shows the placeholder dev buttons.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.apiClient});

  static const path = '/splash';

  final ApiClient? apiClient;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.apiClient != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
    }
  }

  Future<void> _resolve({bool retriedAuth = false}) async {
    try {
      final result = await widget.apiClient!.bootstrap(sessionId: '');
      if (!mounted) return;
      context.go(
        result.recoveryRequired ? '/recover' : entryRouteFor(result.sessionMode),
      );
    } on ApiException catch (e) {
      // Cold-start anonymous sign-in can fail transiently (offline) or race the
      // first bootstrap → a 401. Recover once by signing in and retrying,
      // instead of stranding the user on a dead error screen.
      if (!retriedAuth && (e.statusCode == 401 || e.statusCode == 403)) {
        try {
          await FirebaseAuth.instance.signInAnonymously();
          if (!mounted) return;
          return _resolve(retriedAuth: true);
        } catch (_) {/* fall through to the error state */}
      }
      if (!mounted) return;
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
              ? const CircularProgressIndicator()
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
