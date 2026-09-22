import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/notification_center_screen.dart';
import 'package:ayma_flutter/screens/notification_prefs_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

class _FakeSvc extends NotificationService {
  _FakeSvc(this._items, {Map<String, bool>? prefs})
      : _prefs = prefs ?? {for (final k in notificationCategories.keys) k: true},
        super(
            auth: MockFirebaseAuth(
                signedIn: true, mockUser: MockUser(uid: 'me')));

  final List<AppNotification> _items;
  final Map<String, bool> _prefs;
  final List<String> readIds = [];
  final List<String> dismissedIds = [];
  bool dismissedAll = false;
  final List<(String, bool)> prefWrites = [];

  @override
  Stream<List<AppNotification>> watch() => Stream.value(_items);

  @override
  Stream<int> watchUnreadCount() =>
      Stream.value(_items.where((n) => !n.read).length);

  @override
  Future<void> markRead(String id) async => readIds.add(id);

  @override
  Future<void> markReadMany(Iterable<String> ids) async => readIds.addAll(ids);

  @override
  Future<void> markAllRead(List<AppNotification> current) async {}

  @override
  Future<void> dismiss(String id) async => dismissedIds.add(id);

  @override
  Future<void> dismissAll(List<AppNotification> current) async =>
      dismissedAll = true;

  @override
  Future<Map<String, bool>> readPrefs() async => Map.of(_prefs);

  @override
  Future<void> setPref(String category, bool enabled) async {
    _prefs[category] = enabled;
    prefWrites.add((category, enabled));
  }
}

/// An ApiClient whose `/profiles/mini` returns the given name/photo per uid.
ApiClient _api([Map<String, Map<String, String>> profiles = const {}]) =>
    ApiClient(
      auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      httpClient: MockClient((req) async {
        if (req.url.path == '/profiles/mini') {
          return http.Response(jsonEncode({'profiles': profiles}), 200);
        }
        return http.Response('{}', 200);
      }),
    );

AppNotification _n(String id, String type, String body, String link,
        {bool read = false, String actorUid = ''}) =>
    AppNotification(
      id: id,
      type: type,
      body: body,
      deepLink: link,
      read: read,
      createdAt: DateTime.now(),
      actorUid: actorUid,
    );

Widget _host(NotificationService svc, ApiClient api) => MaterialApp(
      theme: AymaTheme.light,
      home: NotificationCenterScreen(service: svc, apiClient: api),
    );

/// Router host — for tests that tap a row (which calls `context.push`).
Widget _routerHost(NotificationService svc, ApiClient api,
        {List<String>? pushed}) =>
    MaterialApp.router(
      theme: AymaTheme.light,
      routerConfig: GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, __) =>
              NotificationCenterScreen(service: svc, apiClient: api),
        ),
        GoRoute(
          path: '/dm/:id',
          builder: (_, s) {
            pushed?.add('/dm/${s.pathParameters['id']}');
            return Scaffold(body: Text('DM ${s.pathParameters['id']}'));
          },
        ),
        GoRoute(
          path: '/deep-dive/:id',
          builder: (_, s) {
            pushed?.add('/deep-dive/${s.pathParameters['id']}');
            return Scaffold(body: Text('Deep dive ${s.pathParameters['id']}'));
          },
        ),
        GoRoute(
          path: '/match/:id',
          builder: (_, s) {
            pushed?.add('/match/${s.pathParameters['id']}');
            return Scaffold(body: Text('Match ${s.pathParameters['id']}'));
          },
        ),
      ]),
    );

void main() {
  group('deepLinkToRoute', () {
    test('dm_thread maps straight through', () {
      expect(deepLinkToRoute('dm_thread/a__b', myUid: 'a'), '/dm/a__b');
    });
    test('profile maps to the sorted-pair DM thread', () {
      expect(deepLinkToRoute('profile/zeb', myUid: 'amy'), '/dm/amy__zeb');
      expect(deepLinkToRoute('profile/amy', myUid: 'zeb'), '/dm/amy__zeb');
    });
    test('matches and chat/fallback', () {
      expect(deepLinkToRoute('matches', myUid: 'a'), '/matches');
      expect(deepLinkToRoute('chat', myUid: 'a'), '/');
      expect(deepLinkToRoute('weird', myUid: 'a'), '/');
    });
    // A "your match is ready" skill_result notification opens the match
    // report directly, not the chat tab.
    test('match maps to the match report', () {
      expect(deepLinkToRoute('match/m1', myUid: 'a'), '/match/m1');
    });
    // A single new match's push deep-links straight to that match's request
    // screen (Pass/Accept + full profile) rather than the "New from Ayma"
    // list — so tapping the notification opens it directly.
    test('match_request maps to the match request screen', () {
      expect(deepLinkToRoute('match_request/a__bob', myUid: 'a'),
          '/match-request/a__bob');
    });
    // A "your web search is ready" skill_result notification opens the deep
    // dive report directly, not the chat tab.
    test('deep_dive maps to the deep-dive report', () {
      expect(
          deepLinkToRoute('deep_dive/uid_other', myUid: 'a'),
          '/deep-dive/uid_other');
    });
    test('deep_dive id is URI-encoded', () {
      expect(
          deepLinkToRoute('deep_dive/a b', myUid: 'a'), '/deep-dive/a%20b');
    });
  });

  group('AppNotification.resolveActorUid', () {
    test('prefers the stored actor_uid', () {
      expect(_n('1', 'dm_message', 'hi', 'dm_thread/a__me', actorUid: 'a')
          .resolveActorUid('me'), 'a');
    });
    test('derives the other uid from a dm_thread pair key', () {
      expect(_n('1', 'dm_message', 'hi', 'dm_thread/a__me')
          .resolveActorUid('me'), 'a');
      expect(_n('1', 'dm_message', 'hi', 'dm_thread/me__zeb')
          .resolveActorUid('me'), 'zeb');
    });
  });

  testWidgets('does NOT mark everything read just by opening', (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'hey there', 'dm_thread/a__me', actorUid: 'a'),
      _n('2', 'mutual_match', 'You have a new match on Ayma.', 'profile/x',
          read: true),
    ]);
    await tester.pumpWidget(_host(svc, _api()));
    await tester.pumpAndSettle();

    expect(find.text('You have a new match on Ayma.'), findsOneWidget);
    expect(svc.readIds, isEmpty); // nothing read until tapped
  });

  testWidgets('multiple messages from one sender collapse into one row',
      (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'brooo', 'dm_thread/a__me', actorUid: 'a'),
      _n('2', 'dm_message', 'hellooo', 'dm_thread/a__me', actorUid: 'a'),
      _n('3', 'dm_message', 'hey', 'dm_thread/a__me', actorUid: 'a'),
      _n('4', 'dm_message', 'yo', 'dm_thread/b__me', actorUid: 'b'),
    ]);
    final pushed = <String>[];
    await tester.pumpWidget(_routerHost(
        svc,
        _api({
          'a': {'name': 'Ash', 'photo': ''},
          'b': {'name': 'Bo', 'photo': ''},
        }),
        pushed: pushed));
    await tester.pumpAndSettle();

    // One row for Ash with the count, one for Bo without.
    expect(find.text('Ash · 3 new messages'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // the badge

    // Opening Ash's row marks all three of his messages read and navigates.
    await tester.tap(find.text('Ash · 3 new messages'));
    await tester.pumpAndSettle();
    expect(svc.readIds, containsAll(['1', '2', '3']));
    expect(svc.readIds, isNot(contains('4')));
    expect(pushed, ['/dm/a__me']);
  });

  testWidgets(
      'tapping a "web search is ready" notification opens the report, not chat',
      (tester) async {
    final svc = _FakeSvc([
      _n('1', 'skill_result', 'Your web search on yourself is ready.',
          'deep_dive/uid_me'),
    ]);
    final pushed = <String>[];
    await tester.pumpWidget(_routerHost(svc, _api(), pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Your web search on yourself is ready.'));
    await tester.pumpAndSettle();
    expect(pushed, ['/deep-dive/uid_me']);
    expect(svc.readIds, ['1']);
  });

  testWidgets(
      'tapping a "match is ready" notification opens the match report, not chat',
      (tester) async {
    final svc = _FakeSvc([
      _n('1', 'skill_result', 'Your match with Dillu Shakeeb is ready — 31%.',
          'match/lo__hi'),
    ]);
    final pushed = <String>[];
    await tester.pumpWidget(_routerHost(svc, _api(), pushed: pushed));
    await tester.pumpAndSettle();

    await tester
        .tap(find.text('Your match with Dillu Shakeeb is ready — 31%.'));
    await tester.pumpAndSettle();
    expect(pushed, ['/match/lo__hi']);
  });

  testWidgets('read rows render distinctly from unread', (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'unread one', 'dm_thread/a__me',
          actorUid: 'a', read: false),
      _n('2', 'ayma_checkin', 'read one', 'chat', read: true),
    ]);
    await tester.pumpWidget(_host(svc, _api({'a': {'name': 'Ash', 'photo': ''}})));
    await tester.pumpAndSettle();

    // The unread DM group shows a count badge; the read check-in shows none.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('read one'), findsOneWidget);
  });

  testWidgets('swiping a DM group dismisses every message in it',
      (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'first', 'dm_thread/a__me', actorUid: 'a'),
      _n('2', 'dm_message', 'second', 'dm_thread/a__me', actorUid: 'a'),
    ]);
    await tester.pumpWidget(_host(svc, _api({'a': {'name': 'Ash', 'photo': ''}})));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Ash · 2 new messages'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(svc.dismissedIds, containsAll(['1', '2']));
  });

  testWidgets(
      'Mark all read asks first, then marks the unread ones on confirm',
      (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'a', 'dm_thread/a__me', actorUid: 'a'),
      _n('2', 'ayma_checkin', 'b', 'chat', read: true),
    ]);
    await tester.pumpWidget(_host(svc, _api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Mark all read'));
    await tester.pumpAndSettle();
    // The dialog is up; nothing has fired yet.
    expect(find.text('Mark 1 notification as read?'), findsOneWidget);
    expect(svc.readIds, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Mark read'));
    await tester.pumpAndSettle();
    expect(svc.readIds, ['1']);
  });

  testWidgets('Mark all read — Cancel never calls the service', (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'a', 'dm_thread/a__me', actorUid: 'a'),
    ]);
    await tester.pumpWidget(_host(svc, _api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Mark all read'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(svc.readIds, isEmpty);
  });

  testWidgets('Clear all asks first, then dismisses everything on confirm',
      (tester) async {
    final svc = _FakeSvc([_n('1', 'ayma_checkin', 'a', 'chat')]);
    await tester.pumpWidget(_host(svc, _api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    expect(find.text('Clear all notifications?'), findsOneWidget);
    expect(svc.dismissedAll, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pumpAndSettle();
    expect(svc.dismissedAll, isTrue);
  });

  testWidgets('Clear all — Cancel never calls the service', (tester) async {
    final svc = _FakeSvc([_n('1', 'ayma_checkin', 'a', 'chat')]);
    await tester.pumpWidget(_host(svc, _api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(svc.dismissedAll, isFalse);
  });

  testWidgets('prefs screen toggles a category', (tester) async {
    final svc = _FakeSvc(const []);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: NotificationPrefsScreen(service: svc),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Direct messages'), findsOneWidget);
    await tester.tap(find.text('Direct messages'));
    await tester.pumpAndSettle();

    expect(svc.prefWrites, contains(('dm_message', false)));
  });
}
