import 'package:flutter/foundation.dart';

import 'notification_service.dart';

/// Notification-centre filters (founder feedback item 11, Nov 2026;
/// staging port 2026-11-07): the chips row on the Notifications page
/// and Ayma's `set_notification_filter` command share these buckets,
/// so what the user taps and what Ayma sets are the same list. Buckets
/// cover the types the centre actually lists —
/// `NotificationService.watch()` excludes `dm_message` (DMs live on
/// the Messages tab), so there is deliberately no Messages bucket
/// here. Type strings mirror `notifications_schema.py` on the backend.
///
/// The bulk inbox actions (mark-all-read / clear-all /
/// mark-all-conversations-read) remain v2-only; only the filter was
/// ordered into staging.
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

/// The live notification-filter state. The Notifications page listens
/// and applies changes, so a filter Ayma sets (she also navigates
/// there) is already in place when the page shows — the same
/// shared-state shape as VoiceClipRegistry.
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
