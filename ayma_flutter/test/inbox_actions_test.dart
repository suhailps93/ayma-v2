import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/inbox_actions.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

AppNotification _n(String id, String type, {bool read = false}) =>
    AppNotification(
      id: id,
      type: type,
      body: 'body',
      deepLink: '',
      read: read,
      createdAt: null,
    );

void main() {
  group('NotificationFilter', () {
    final items = [
      _n('1', 'mutual_match'),
      _n('2', 'new_scored_match', read: true),
      _n('3', 'ayma_checkin'),
      _n('4', 'ayma_reply', read: true),
      _n('5', 'skill_result'),
      _n('6', 'report_ready'),
      _n('7', 'profile_suggestions'),
      _n('8', 'dm_message'),
    ];

    List<String> ids(NotificationFilter f) =>
        filterNotifications(items, f).map((n) => n.id).toList();

    test('buckets match the types the centre lists', () {
      expect(ids(NotificationFilter.all),
          ['1', '2', '3', '4', '5', '6', '7', '8']);
      expect(ids(NotificationFilter.unread), ['1', '3', '5', '6', '7', '8']);
      expect(ids(NotificationFilter.matches), ['1', '2']);
      expect(ids(NotificationFilter.ayma), ['3', '4', '5']);
      expect(ids(NotificationFilter.reports), ['6']);
      expect(ids(NotificationFilter.suggestions), ['7']);
    });

    test('fromKey round-trips and defaults unknown keys to all', () {
      for (final f in NotificationFilter.values) {
        expect(NotificationFilter.fromKey(f.key), f);
      }
      expect(NotificationFilter.fromKey('nope'), NotificationFilter.all);
      expect(NotificationFilter.fromKey(''), NotificationFilter.all);
    });
  });

  group('AppCommandService inbox commands', () {
    AppCommandService svc({
      int notifRead = 0,
      int cleared = 0,
      int convRead = 0,
      bool fail = false,
      List<String>? nav,
    }) {
      Future<int> Function() op(int value) =>
          () async => fail ? throw StateError('boom') : value;
      return AppCommandService(
        navigate: nav?.add ?? (_) {},
        inboxActions: InboxActions(
          markAllNotificationsRead: op(notifRead),
          clearAllNotifications: op(cleared),
          markAllConversationsRead: op(convRead),
        ),
      );
    }

    test('mark_all_notifications_read relays the count', () async {
      final out = await svc(notifRead: 3)
          .runInboxCommand({'action': 'mark_all_notifications_read'});
      expect(out.ok, isTrue);
      expect(out.message, 'Marked 3 notifications as read.');
      final zero = await svc()
          .runInboxCommand({'action': 'mark_all_notifications_read'});
      expect(zero.message, 'No unread notifications.');
    });

    test('clear_all_notifications relays the count', () async {
      final out = await svc(cleared: 1)
          .runInboxCommand({'action': 'clear_all_notifications'});
      expect(out.ok, isTrue);
      expect(out.message, 'Cleared 1 notification.');
    });

    test('mark_all_conversations_read relays the count', () async {
      final out = await svc(convRead: 2)
          .runInboxCommand({'action': 'mark_all_conversations_read'});
      expect(out.ok, isTrue);
      expect(out.message, 'Marked 2 conversations as read.');
    });

    test('set_notification_filter sets the shared state and navigates',
        () async {
      NotificationFilterState.instance
          .setFilter(NotificationFilter.all);
      final nav = <String>[];
      final out = await svc(nav: nav).runInboxCommand(
          {'action': 'set_notification_filter', 'filter': 'unread'});
      expect(out.ok, isTrue);
      expect(out.message, 'Showing Unread notifications.');
      expect(NotificationFilterState.instance.current.value,
          NotificationFilter.unread);
      expect(nav, ['/notifications']);
      NotificationFilterState.instance
          .setFilter(NotificationFilter.all);
    });

    test('a failing op is an honest failure, never a throw', () async {
      final out = await svc(fail: true)
          .runInboxCommand({'action': 'mark_all_notifications_read'});
      expect(out.ok, isFalse);
      expect(out.message, 'That inbox action failed.');
    });

    test('an unknown inbox action is refused', () async {
      final out = await svc().runInboxCommand({'action': 'nuke_inbox'});
      expect(out.ok, isFalse);
      expect(out.message, contains('Unknown inbox action'));
    });
  });

  group('InboxActions injectable ops', () {
    test('returns the op counts untouched', () async {
      final actions = InboxActions(
        markAllNotificationsRead: () async => 4,
        clearAllNotifications: () async => 9,
        markAllConversationsRead: () async => 1,
      );
      expect(await actions.markAllNotificationsRead(), 4);
      expect(await actions.clearAllNotifications(), 9);
      expect(await actions.markAllConversationsRead(), 1);
    });
  });
}
