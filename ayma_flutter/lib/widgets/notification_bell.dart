import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/notification_center_screen.dart';
import '../services/notification_service.dart';
import '../theme.dart';

/// App-bar bell that opens the notification centre (§7.3, §11.3) and shows the
/// unread count as a badge (§7.9 step 8).
///
/// The unread subscription is best-effort: if there's no signed-in user / no
/// Firebase (pure widget tests), it renders a plain bell with no badge.
class NotificationBellButton extends StatefulWidget {
  const NotificationBellButton({super.key, this.service});

  final NotificationService? service;

  @override
  State<NotificationBellButton> createState() => _NotificationBellButtonState();
}

class _NotificationBellButtonState extends State<NotificationBellButton> {
  StreamSubscription<int>? _sub;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    try {
      final svc = widget.service ?? NotificationService();
      _sub = svc.watchUnreadCount().listen(
            (c) {
              if (mounted) setState(() => _count = c);
            },
            onError: (_) {},
          );
    } catch (_) {
      // No auth / Firebase — plain bell.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => context.push(NotificationCenterScreen.path),
      icon: Badge(
        isLabelVisible: _count > 0,
        label: Text(_count > 99 ? '99+' : '$_count'),
        backgroundColor: ac.accent,
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}
