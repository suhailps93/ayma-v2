import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/notification_service.dart';
import '../theme.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/staggered.dart';
import 'notification_prefs_screen.dart';

/// Notification centre (§7.3, §7.9 step 8): the most recent notifications,
/// newest first. Multiple unread messages from the same person collapse into a
/// single row with their face, name and an unread count; opening it takes you
/// to that conversation and marks those messages read. Read vs unread is shown
/// clearly — nothing is marked read just by opening this screen.
class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key, this.service, this.apiClient});

  static const path = '/notifications';

  final NotificationService? service;
  final ApiClient? apiClient;

  @override
  State<NotificationCenterScreen> createState() =>
      _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  late final NotificationService _svc = widget.service ?? NotificationService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final String _myUid = _svc.currentUid;

  final Map<String, MiniProfile> _mini = {};

  void _ensureMini(Set<String> uids) {
    final missing =
        uids.where((u) => u.isNotEmpty && !_mini.containsKey(u)).toList();
    if (missing.isEmpty) return;
    _api.miniProfiles(missing).then((m) {
      if (mounted && m.isNotEmpty) setState(() => _mini.addAll(m));
    }).catchError((_) {/* fall back to the initial letter */});
  }

  /// Fold the flat list into rows: one per non-DM notification, one per DM
  /// sender (all their unread messages together), newest-first by first
  /// appearance.
  List<_Entry> _entries(List<AppNotification> items) {
    final out = <_Entry>[];
    final dmIndex = <String, int>{}; // actor key -> index in `out`
    for (final n in items) {
      if (n.type == 'dm_message') {
        final key = n.resolveActorUid(_myUid);
        final bucket = key.isEmpty ? n.deepLink : key;
        final at = dmIndex[bucket];
        if (at == null) {
          dmIndex[bucket] = out.length;
          out.add(_Entry.dmGroup([n], key));
        } else {
          out[at].group.add(n);
        }
      } else {
        out.add(_Entry.single(n));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return StreamBuilder<List<AppNotification>>(
      stream: _svc.watch(),
      builder: (context, snap) {
        final items = snap.data ?? const <AppNotification>[];
        final entries = _entries(items);
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureMini(
            entries.where((e) => e.isDmGroup).map((e) => e.actorUid).toSet()));

        return Scaffold(
          appBar: AppBar(
            title: const Text('Notifications'),
            actions: [
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Mark all read',
                  icon: const Icon(Icons.done_all),
                  onPressed: () => _confirmMarkAllRead(items),
                ),
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Clear all',
                  icon: const Icon(Icons.clear_all),
                  onPressed: () => _confirmClearAll(items),
                ),
              IconButton(
                tooltip: 'Preferences',
                icon: const Icon(Icons.tune),
                onPressed: () => context.push(NotificationPrefsScreen.path),
              ),
            ],
          ),
          body: Builder(builder: (context) {
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
            if (entries.isEmpty) {
              return Center(
                child: Text('Nothing here yet.',
                    style: AymaType.sans(
                        size: 15, soft: true, color: ac.fgMute)),
              );
            }
            return ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: ac.lineSoft),
              itemBuilder: (context, i) {
                final e = entries[i];
                return Dismissible(
                  key: ValueKey(e.isDmGroup ? 'dm:${e.actorUid}:${e.notif.id}'
                      : e.notif.id),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) => _dismissEntry(e),
                  background: Container(
                    color: ac.lineSoft,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: Icon(Icons.close, size: 18, color: ac.fgMute),
                  ),
                  child: FadeSlideIn(
                    delay: staggerDelay(i),
                    child: _EntryRow(
                      entry: e,
                      mini: e.isDmGroup ? _mini[e.actorUid] : null,
                      onTap: () => _open(e),
                    ),
                  ),
                );
              },
            );
          }),
        );
      },
    );
  }

  /// Confirms before marking everything read — lower-stakes than Clear all,
  /// but still a bulk action the founder wants a check on (§7.9).
  Future<void> _confirmMarkAllRead(List<AppNotification> items) async {
    final unread = items.where((n) => !n.read).toList();
    if (unread.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Mark ${unread.length} notification'
          '${unread.length == 1 ? '' : 's'} as read?',
        ),
        content: const Text("They'll no longer show as unread."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark read')),
        ],
      ),
    );
    if (ok != true) return;
    _svc.markReadMany(unread.map((n) => n.id));
  }

  Future<void> _confirmClearAll(List<AppNotification> items) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all notifications?'),
        content: const Text(
          "They'll be removed from this list. This cannot be undone.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear all')),
        ],
      ),
    );
    if (ok != true) return;
    _svc.dismissAll(items);
  }

  Future<void> _dismissEntry(_Entry e) async {
    // Reuse the soft-dismiss write for every id the row covers.
    for (final id in e.ids) {
      await _svc.dismiss(id);
    }
  }

  Future<void> _open(_Entry e) async {
    await _svc.markReadMany(e.ids);
    if (!mounted) return;
    context.push(deepLinkToRoute(e.notif.deepLink, myUid: _myUid));
  }
}

/// One notification-centre row: a single non-DM notification, or a DM sender
/// with all of their messages folded together.
class _Entry {
  _Entry.single(AppNotification n)
      : notif = n,
        group = <AppNotification>[],
        actorUid = '';

  _Entry.dmGroup(List<AppNotification> g, this.actorUid)
      : notif = g.first,
        group = g;

  /// The newest notification in the row (the representative).
  final AppNotification notif;

  /// Every DM in the group, newest first. Empty for a single non-DM row.
  final List<AppNotification> group;
  final String actorUid;

  bool get isDmGroup => group.isNotEmpty;

  List<String> get ids =>
      isDmGroup ? group.map((n) => n.id).toList() : <String>[notif.id];

  int get unreadCount => isDmGroup
      ? group.where((n) => !n.read).length
      : (notif.read ? 0 : 1);

  bool get read => unreadCount == 0;

  DateTime? get when => notif.createdAt;
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.mini, required this.onTap});

  final _Entry entry;
  final MiniProfile? mini;
  final VoidCallback onTap;

  static const _icons = {
    'dm_message': Icons.chat_bubble_outline,
    'mutual_match': Icons.favorite_border,
    'new_scored_match': Icons.auto_awesome_outlined,
    'ayma_checkin': Icons.waving_hand_outlined,
    'skill_result': Icons.insights_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final unread = !entry.read;
    final n = entry.notif;
    final count = entry.unreadCount;

    final String title;
    final String? line;
    if (entry.isDmGroup) {
      final name = (mini?.name.isNotEmpty ?? false) ? mini!.name : 'Someone';
      title = count > 1 ? '$name · $count new messages' : name;
      line = n.body.isEmpty ? 'New message' : n.body;
    } else {
      title = n.body.isEmpty
          ? (notificationCategories[n.type] ?? n.type)
          : n.body;
      line = null;
    }

    return Container(
      // Unread rows carry a soft accent wash + a left bar so read vs unread
      // reads at a glance.
      decoration: BoxDecoration(
        color: unread ? ac.accent.withValues(alpha: 0.06) : null,
        border: Border(
          left: BorderSide(
            color: unread ? ac.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      // A plain Material (transparent) between the colored Container above
      // and the ListTile below: ListTile paints its own background/ink
      // splashes on its nearest Material ancestor, and without this, the
      // Container's own BoxDecoration background sits on top of that paint
      // and hides it (Flutter's ListTile now asserts on this in debug mode).
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          onTap: onTap,
          leading: entry.isDmGroup
              ? _Avatar(mini: mini, unread: unread)
              : Icon(_icons[n.type] ?? Icons.notifications_none,
                  color: unread ? ac.accent : ac.fgMute),
          title: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AymaType.sans(
                size: 14,
                color: unread ? ac.fg : ac.fgDim,
                weight: unread ? FontWeight.w600 : FontWeight.w400),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                if (line != null && line.isNotEmpty) line,
                if (entry.when != null) _ago(entry.when!),
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ),
          trailing: count > 0
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: ac.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('$count',
                      style: AymaType.mono(size: 10, color: Colors.white)),
                )
              : null,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.mini, required this.unread});
  final MiniProfile? mini;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final photo = mini?.photo ?? '';
    final name = mini?.name ?? '';
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: photo.isEmpty
            ? Container(
                color: ac.bgCard,
                alignment: Alignment.center,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: AymaType.serif(size: 16, color: ac.fgMute),
                ),
              )
            : AymaPhoto(url: photo, displayWidth: 40),
      ),
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
