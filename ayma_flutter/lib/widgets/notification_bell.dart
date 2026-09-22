import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/notification_center_screen.dart';
import '../services/notification_service.dart';
import '../theme.dart';

/// Bell that opens the notification centre (§7.3, §11.3) and shows the
/// unread count as a badge (§7.9 step 8). Lives in the bottom nav bar
/// (`MainShellScreen`'s `_AymaTabBar`) as a push-only entry — Notifications
/// isn't one of the shell's persistent `IndexedStack` tabs, so tapping it
/// pushes the route rather than switching pages.
///
/// The unread subscription is best-effort: if there's no signed-in user / no
/// Firebase (pure widget tests), it renders a plain bell with no badge.
class NotificationBellButton extends StatefulWidget {
  const NotificationBellButton({
    super.key,
    this.service,
    this.compact = false,
    this.iconColor,
  });

  final NotificationService? service;

  /// Nav-bar rendering: a bare icon + badge, sized to match the tab bar's
  /// other icons, with no `IconButton` chrome or tooltip of its own — the
  /// caller (`_AymaTabBar`'s `_Tab`) already supplies both the tap target
  /// and the tooltip, matching every other tab exactly.
  final bool compact;

  /// Icon color in [compact] mode (defaults to the theme's icon color).
  /// Ignored otherwise — the header rendering always uses the default
  /// [IconButton] color.
  final Color? iconColor;

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
    final badge = Badge(
      isLabelVisible: _count > 0,
      label: Text(_count > 99 ? '99+' : '$_count'),
      backgroundColor: ac.accent,
      child: Icon(
        Icons.notifications_none_rounded,
        size: widget.compact ? 22 : null,
        color: widget.compact ? widget.iconColor : null,
      ),
    );
    if (widget.compact) return badge;
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => context.push(NotificationCenterScreen.path),
      icon: badge,
    );
  }
}
