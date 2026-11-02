import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/messages_unread_icon.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MockFirebaseAuth _auth() =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

Future<void> _thread(FakeFirebaseFirestore fs, String other, int unread) =>
    fs.doc('dm_threads/${other}__me').set({
      'participants': [other, 'me'],
      'last_message_at': Timestamp.now(),
      'last_read_at': <String, dynamic>{},
      'unread': <String, dynamic>{'me': unread, other: 0},
    });

class _NoMatches extends MatchService {
  _NoMatches() : super(auth: _auth());
  @override
  Stream<List<MatchView>> watchMutualMatches({int limit = 25}) =>
      Stream.value(const []);
}

class _NoApi extends ApiClient {
  _NoApi() : super(auth: _auth());
  @override
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async =>
      {};
}

void main() {
  group('DmService unread', () {
    test('total unread sums my counters across threads', () async {
      final fs = FakeFirebaseFirestore();
      await _thread(fs, 'a', 2);
      await _thread(fs, 'b', 3);
      final svc = DmService(auth: _auth(), firestore: fs);
      expect(await svc.watchTotalUnread().first, 5);
    });

    test('threads without an unread map count as zero', () async {
      final fs = FakeFirebaseFirestore();
      await fs.doc('dm_threads/a__me').set({
        'participants': ['a', 'me'],
        'last_message_at': Timestamp.now(),
      });
      final svc = DmService(auth: _auth(), firestore: fs);
      expect(await svc.watchTotalUnread().first, 0);
    });

    test('markThreadRead zeroes only my counter and stamps my cursor',
        () async {
      final fs = FakeFirebaseFirestore();
      await _thread(fs, 'a', 4);
      final svc = DmService(auth: _auth(), firestore: fs);
      await svc.markThreadRead('a__me');
      final d = (await fs.doc('dm_threads/a__me').get()).data()!;
      expect((d['unread'] as Map)['me'], 0);
      expect((d['unread'] as Map).keys, containsAll(['me', 'a']));
      expect((d['last_read_at'] as Map)['me'], isNotNull);
      expect(await svc.watchTotalUnread().first, 0);
    });

    test('markThreadRead on a missing thread is a no-op', () async {
      final svc = DmService(auth: _auth(), firestore: FakeFirebaseFirestore());
      await svc.markThreadRead('a__me');
    });
  });

  test('notification centre hides DM entries and the bell ignores them',
      () async {
    final fs = FakeFirebaseFirestore();
    final col = fs.collection('users/me/notifications');
    await col.doc('1').set({
      'type': 'dm_message',
      'body': 'hello',
      'deep_link': 'dm_thread/a__me',
      'read': false,
      'created_at': Timestamp.now(),
    });
    await col.doc('2').set({
      'type': 'mutual_match',
      'body': 'match',
      'deep_link': 'profile/b',
      'read': false,
      'created_at': Timestamp.now(),
    });
    final svc = NotificationService(auth: _auth(), firestore: fs);
    expect((await svc.watch().first).map((n) => n.id), ['2']);
    expect(await svc.watchUnreadCount().first, 1);
  });

  testWidgets('tab icon shows total unread badge, capped at 99+',
      (tester) async {
    final fs = FakeFirebaseFirestore();
    await _thread(fs, 'a', 4);
    await _thread(fs, 'b', 3);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: MessagesUnreadIcon(
          icon: Icons.mail_outline_rounded,
          color: Colors.black,
          service: DmService(auth: _auth(), firestore: fs),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('7'), findsOneWidget);

    await fs.doc('dm_threads/a__me').update({'unread.me': 200});
    await tester.pump();
    await tester.pump();
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('messages row shows unread badge only for unread threads',
      (tester) async {
    final fs = FakeFirebaseFirestore();
    await _thread(fs, 'a', 3);
    await _thread(fs, 'b', 0);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: MessagesScreen(
        dmService: DmService(auth: _auth(), firestore: fs),
        matchService: _NoMatches(),
        apiClient: _NoApi(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('unread-badge')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
