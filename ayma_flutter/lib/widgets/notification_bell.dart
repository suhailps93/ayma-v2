import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/notification_center_screen.dart';
import '../theme.dart';

/// App-bar bell that opens the notification center (§7.3, §11.3). The unread
/// [count] renders as a badge; the live count is wired in Phase 9 (Step 57),
/// so callers pass 0 until then.
class NotificationBellButton extends StatelessWidget {
  const NotificationBellButton({super.key, this.count = 0});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => context.push(NotificationCenterScreen.path),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        backgroundColor: ac.accent,
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}
