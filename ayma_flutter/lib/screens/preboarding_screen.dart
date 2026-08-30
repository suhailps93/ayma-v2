import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Placeholder preboarding screen (Step 4).
///
/// The real 6-screen preboarding sequence (name, birthdate, gender,
/// interested_in, location, photo) — typed in Step 7, voice-driven in Step 31 —
/// replaces this. For now: dev buttons only.
class PreboardingScreen extends StatelessWidget {
  const PreboardingScreen({super.key});

  static const path = '/preboarding';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Preboarding (placeholder)')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Preboarding (placeholder)'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/splash'),
              child: const Text('Go to Splash'),
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
