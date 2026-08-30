import 'package:flutter/material.dart';

import '../theme.dart';

/// Notification center (§7.3, §7.9 steps 8–9). This is the routed shell only —
/// the list, read-state, deep-link tap-through, and per-category preferences are
/// built in Phase 9 (Step 57). Wiring the route now lets the app-bar bell
/// (§11.3) land somewhere real from Step 53 onward.
class NotificationCenterScreen extends StatelessWidget {
  const NotificationCenterScreen({super.key});

  static const path = '/notifications';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing here yet.',
            style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
          ),
        ),
      ),
    );
  }
}
