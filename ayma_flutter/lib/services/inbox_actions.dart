import 'package:flutter/foundation.dart';

import 'dm_service.dart';
import 'notification_service.dart';

/// Notification-centre filters (founder feedback item 11, Nov 2026): the
/// chips row on the Notifications page and Ayma's `set_notification_filter`
/// command share these buckets, so what the user taps and what Ayma sets
/// are the same list. Buckets cover the types the centre actually lists —
/// `NotificationService.watch()` excludes `dm_message` (DMs live on the
/// Messages tab), so there is deliberately no Messages bucket here. Type
/// strings mirror `notifications_schema.py` on the backend.
enum NotificationFilter {
  all('all', 'All'),
  unread('unread', 'Unread'),
  matches('matches', 'Matches'),
  ayma('ayma', 'Ayma'),
  reports('reports', 'Reports'),
  suggestions('suggestions', 'Suggestions');

  const NotificationFilter(this.key, this.label);

  final String key;
  final String label;

  static NotificationFilter fromKey(String key) => values.firstWhere(
      (f) => f.key == key,
      orElse: () => NotificationFilter.all);

  bool accepts(AppNotification n) => switch (this) {
        NotificationFilter.all => true,
        NotificationFilter.unread => !n.read,
        NotificationFilter.matches =>
          n.type == 'mutual_match' || n.type == 'new_scored_match',
        NotificationFilter.ayma => n.type == 'ayma_checkin' ||
            n.type == 'ayma_reply' ||
            n.type == 'skill_result',
        NotificationFilter.reports => n.type == 'report_ready',
        NotificationFilter.suggestions => n.type == 'profile_suggestions',
      };
}

/// The notifications visible under [filter] — the centre's list logic,
/// shared by the screen and tests.
List<AppNotification> filterNotifications(
        List<AppNotification> items, NotificationFilter filter) =>
    items.where(filter.accepts).toList();

/// The live notification-filter state. The Notifications page listens and
/// applies changes, so a filter Ayma sets (she also navigates there) is
/// already in place when the page shows — the same shared-state shape
/// as VoiceClipRegistry.
class NotificationFilterState {
  NotificationFilterState._();
  static final NotificationFilterState instance = NotificationFilterState._();

  final ValueNotifier<NotificationFilter> current =
      ValueNotifier<NotificationFilter>(NotificationFilter.all);

  void setFilter(NotificationFilter filter) => current.value = filter;
}

/// Outcome of one inbox command: whether it ran, and the line the ack
/// carries back (what happened, or why nothing did).
class InboxActionResult {
  const InboxActionResult(this.ok, this.message);

  final bool ok;
  final String message;
}

/// The bulk inbox actions Ayma can run (ACTION PARITY priority gaps,
/// founder feedback items 9–11): mark every notification read, clear
/// every notification, mark every conversation read. The
/// NotificationService / DmService writes underneath are the same ones
/// the on-screen buttons run. Ops are injectable so command dispatch is
/// testable without Firebase; the real services are only constructed
/// when an op actually runs.
class InboxActions {
  InboxActions({
    Future<int> Function()? markAllNotificationsRead,
    Future<int> Function()? clearAllNotifications,
    Future<int> Function()? markAllConversationsRead,
    this._notificationService,
    this._dmService,
  })  : _markAllNotificationsReadOp = markAllNotificationsRead,
        _clearAllNotificationsOp = clearAllNotifications,
        _markAllConversationsReadOp = markAllConversationsRead;

  final Future<int> Function()? _markAllNotificationsReadOp;
  final Future<int> Function()? _clearAllNotificationsOp;
  final Future<int> Function()? _markAllConversationsReadOp;
  final NotificationService? _notificationService;
  final DmService? _dmService;

  /// Marks every unread notification read; returns how many were unread.
  Future<int> markAllNotificationsRead() async {
    final op = _markAllNotificationsReadOp;
    if (op != null) return op();
    final svc = _notificationService ?? NotificationService();
    final items = await svc.watch().first;
    final unread = items.where((n) => !n.read).length;
    if (unread > 0) await svc.markAllRead(items);
    return unread;
  }

  /// Soft-dismisses every notification; returns how many were cleared.
  Future<int> clearAllNotifications() async {
    final op = _clearAllNotificationsOp;
    if (op != null) return op();
    final svc = _notificationService ?? NotificationService();
    final items = await svc.watch().first;
    if (items.isNotEmpty) await svc.dismissAll(items);
    return items.length;
  }

  /// Marks every conversation with unread messages read; returns how
  /// many conversations were marked.
  Future<int> markAllConversationsRead() async {
    final op = _markAllConversationsReadOp;
    if (op != null) return op();
    return (_dmService ?? DmService()).markAllThreadsRead();
  }
}
