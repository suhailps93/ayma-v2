import 'dart:async';

import 'package:flutter/material.dart';

import '../services/dm_service.dart';
import '../theme.dart';

/// The Messages tab icon with a live badge of total unread DM messages across
/// threads — same badge style and cap as the Notifications bell. Best-effort:
/// with no signed-in user / Firebase (pure widget tests) it renders the bare
/// icon.
class MessagesUnreadIcon extends StatefulWidget {
  const MessagesUnreadIcon({
    super.key,
    required this.icon,
    required this.color,
    this.service,
  });

  final IconData icon;
  final Color color;
  final DmService? service;

  @override
  State<MessagesUnreadIcon> createState() => _MessagesUnreadIconState();
}

class _MessagesUnreadIconState extends State<MessagesUnreadIcon> {
  StreamSubscription<int>? _sub;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    try {
      _sub = (widget.service ?? DmService()).watchTotalUnread().listen(
            (c) {
              if (mounted) setState(() => _count = c);
            },
            onError: (_) {},
          );
    } catch (_) {
      // No auth / Firebase — plain icon.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: _count > 0,
      label: Text(_count > 99 ? '99+' : '$_count'),
      backgroundColor: context.ac.accent,
      textColor: context.ac.onAccent,
      child: Icon(widget.icon, size: 22, color: widget.color),
    );
  }
}
