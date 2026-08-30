import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Placeholder main app shell (Step 4).
///
/// The real 4-tab shell (Ayma / Explore / Messages / Profile) with the orb
/// center tab and notification bell is assembled in Step 53 (§11.3). For now
/// it's one placeholder screen with dev navigation.
class MainShellScreen extends StatelessWidget {
  const MainShellScreen({super.key});

  static const path = '/';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Main shell (placeholder)')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Main shell (placeholder)'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/splash'),
              child: const Text('Go to Splash'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => context.go('/preboarding'),
              child: const Text('Go to Preboarding'),
            ),
          ],
        ),
      ),
    );
  }
}
