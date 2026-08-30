import 'dart:async';

import 'package:ayma_flutter/screens/notification_center_screen.dart';
import 'package:ayma_flutter/screens/notification_prefs_screen.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeSvc extends NotificationService {
  _FakeSvc(this._items, {Map<String, bool>? prefs})
      : _prefs = prefs ?? {for (final k in notificationCategories.keys) k: true},
        super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  final List<AppNotification> _items;
  final Map<String, bool> _prefs;
  final List<String> readIds = [];
  bool markedAll = false;
  final List<(String, bool)> prefWrites = [];

  @override
  Stream<List<AppNotification>> watch() => Stream.value(_items);

  @override
  Stream<int> watchUnreadCount() =>
      Stream.value(_items.where((n) => !n.read).length);

  @override
  Future<void> markRead(String id) async => readIds.add(id);

  @override
  Future<void> markAllRead(List<AppNotification> current) async =>
      markedAll = true;

  @override
  Future<Map<String, bool>> readPrefs() async => Map.of(_prefs);

  @override
  Future<void> setPref(String category, bool enabled) async {
    _prefs[category] = enabled;
    prefWrites.add((category, enabled));
  }
}

AppNotification _n(String id, String type, String body, String link,
        {bool read = false}) =>
    AppNotification(
      id: id,
      type: type,
      body: body,
      deepLink: link,
      read: read,
      createdAt: DateTime.now(),
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
  });

  testWidgets('lists notifications and marks all read on open', (tester) async {
    final svc = _FakeSvc([
      _n('1', 'dm_message', 'hey there', 'dm_thread/a__me'),
      _n('2', 'mutual_match', 'You have a new match on Ayma.', 'profile/x',
          read: true),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: NotificationCenterScreen(service: svc),
    ));
    await tester.pumpAndSettle();

    expect(find.text('hey there'), findsOneWidget);
    expect(find.text('You have a new match on Ayma.'), findsOneWidget);
    expect(svc.markedAll, isTrue);
  });

  testWidgets('tapping a row marks it read and navigates', (tester) async {
    final svc = _FakeSvc([_n('1', 'dm_message', 'ping', 'dm_thread/a__me')]);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => NotificationCenterScreen(service: svc),
      ),
      GoRoute(
        path: '/dm/:id',
        builder: (_, s) => Scaffold(body: Text('DM ${s.pathParameters['id']}')),
      ),
    ]);
    await tester.pumpWidget(MaterialApp.router(
      theme: AymaTheme.light,
      routerConfig: router,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ping'));
    await tester.pumpAndSettle();
    expect(svc.readIds, contains('1'));
    expect(find.text('DM a__me'), findsOneWidget);
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
