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
    AppCommandService svc({List<String>? nav}) {
      return AppCommandService(
        navigate: nav?.add ?? (_) {},
      );
    }

    test('set_notification_filter sets the shared state and navigates',
        () async {
      NotificationFilterState.instance.setFilter(NotificationFilter.all);
      final nav = <String>[];
      final out = await svc(nav: nav).runInboxCommand(
          {'action': 'set_notification_filter', 'filter': 'unread'});
      expect(out.ok, isTrue);
      expect(out.message, 'Showing Unread notifications. (was: all)');
      expect(NotificationFilterState.instance.current.value,
          NotificationFilter.unread);
      expect(nav, ['/notifications']);
      NotificationFilterState.instance.setFilter(NotificationFilter.all);
    });

    test('set_notification_filter reports the filter it replaced', () async {
      NotificationFilterState.instance
          .setFilter(NotificationFilter.matches);
      final out = await svc().runInboxCommand(
          {'action': 'set_notification_filter', 'filter': 'unread'});
      expect(out.ok, isTrue);
      expect(out.message, 'Showing Unread notifications. (was: matches)');
      expect(NotificationFilterState.instance.current.value,
          NotificationFilter.unread);
      NotificationFilterState.instance.setFilter(NotificationFilter.all);
    });

    test('an unknown inbox action is refused', () async {
      final out = await svc().runInboxCommand({'action': 'nuke_inbox'});
      expect(out.ok, isFalse);
      expect(out.message, contains('Unknown inbox action'));
    });

    test('the v2-only bulk actions are not wired on staging', () async {
      // Staging split: mark-all-read / clear-all / mark-all-
      // conversations-read were NOT ported with the filter.
      for (final action in [
        'mark_all_notifications_read',
        'clear_all_notifications',
        'mark_all_conversations_read',
      ]) {
        final out = await svc().runInboxCommand({'action': action});
        expect(out.ok, isFalse, reason: action);
        expect(out.message, contains('Unknown inbox action'));
      }
    });
  });
}
