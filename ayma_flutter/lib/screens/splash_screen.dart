import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Placeholder splash screen (Step 4).
///
/// The real entry flow — auth-state check then a `session_mode`-driven redirect
/// to marketing / interview / active — is wired in later steps (§11.2, Step 34).
/// For now it just offers dev buttons to jump to the other placeholder screens.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  static const path = '/splash';

  @override
  Widget build(BuildContext context) {
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
          ],
        ),
      ),
    );
  }
}
