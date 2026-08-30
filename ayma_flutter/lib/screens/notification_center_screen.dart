import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/notification_service.dart';
import '../theme.dart';
import 'notification_prefs_screen.dart';

/// Notification centre (§7.3, §7.9 step 8): the most recent notifications,
/// newest first. Opening the screen marks everything read; tapping a row
/// deep-links to the right place (§7.6).
class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key, this.service});

  static const path = '/notifications';

  final NotificationService? service;

  @override
  State<NotificationCenterScreen> createState() =>
      _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  late final NotificationService _svc = widget.service ?? NotificationService();
  late final String _myUid = _svc.currentUid;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Preferences',
            icon: const Icon(Icons.tune),
            onPressed: () => context.push(NotificationPrefsScreen.path),
          ),
        ],
      ),
      body: StreamBuilder<List<AppNotification>>(
        stream: _svc.watch(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load notifications (${snap.error}).',
                    style: AymaType.sans(size: 14, color: AymaColors.error)),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Text('Nothing here yet.',
                  style:
                      AymaType.sans(size: 15, soft: true, color: ac.fgMute)),
            );
          }
          // Opening the list clears unread state (§7.9 step 8).
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => _svc.markAllRead(items));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: ac.lineSoft),
            itemBuilder: (context, i) => _Row(
              n: items[i],
              onTap: () async {
                await _svc.markRead(items[i].id);
                if (!context.mounted) return;
                context.go(deepLinkToRoute(items[i].deepLink, myUid: _myUid));
              },
            ),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.n, required this.onTap});
  final AppNotification n;
  final VoidCallback onTap;

  static const _icons = {
    'dm_message': Icons.chat_bubble_outline,
    'mutual_match': Icons.favorite_border,
    'new_scored_match': Icons.auto_awesome_outlined,
    'ayma_checkin': Icons.waving_hand_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ListTile(
      onTap: onTap,
      leading: Icon(_icons[n.type] ?? Icons.notifications_none,
          color: n.read ? ac.fgMute : ac.accent),
      title: Text(
        n.body.isEmpty ? notificationCategories[n.type] ?? n.type : n.body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AymaType.sans(
            size: 14,
            color: ac.fg,
            weight: n.read ? FontWeight.w400 : FontWeight.w600),
      ),
      subtitle: n.createdAt == null
          ? null
          : Text(_ago(n.createdAt!),
              style:
                  AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
      trailing: n.read
          ? null
          : Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: ac.accent, shape: BoxShape.circle)),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
