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

  Future<void> _resolve() async {
    try {
      final result = await widget.apiClient!.bootstrap(sessionId: '');
      if (!mounted) return;
      context.go(entryRouteFor(result.sessionMode));
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
                  child: Text(_error!, textAlign: TextAlign.center),
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
