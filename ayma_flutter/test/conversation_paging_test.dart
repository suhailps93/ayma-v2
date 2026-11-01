import 'dart:convert';

import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MockFirebaseAuth _auth() =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

Future<void> _thread(
  FakeFirebaseFirestore fs,
  String other,
  DateTime at, {
  int unread = 0,
}) =>
    fs.doc('dm_threads/${other}__me').set({
      'participants': [other, 'me'],
      'last_message_at': Timestamp.fromDate(at),
      'unread': <String, dynamic>{'me': unread, other: 0},
    });

Future<void> _match(
  FakeFirebaseFirestore fs,
  String other, {
  double score = 0.5,
}) =>
    fs.doc('matches/${other}__me').set({
      'uids': [other, 'me'],
      'status': 'mutual_interest',
      'score': score,
      'user_explanation': <String, dynamic>{},
    });

class _CountingApi extends ApiClient {
  _CountingApi() : super(auth: _auth());
  int miniCalls = 0;
  List<String> lastUids = const [];
  @override
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async {
    miniCalls++;
    lastUids = List.of(uids);
    return {
      for (final u in uids)
        u: MiniProfile(name: 'Mini $u', photo: '', online: false),
    };
  }
}

class _FailingApi extends ApiClient {
  _FailingApi() : super(auth: _auth());
  @override
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async =>
      throw ApiException('offline');
}

void main() {
  group('DmService thread paging (design §3.2)', () {
    test('watchThreads is bounded to 25, newest first', () async {
      final fs = FakeFirebaseFirestore();
      final base = DateTime(2026, 1, 1);
      for (var i = 0; i < 30; i++) {
        await _thread(fs, 'u$i', base.add(Duration(hours: i)));
      }
      final svc = DmService(auth: _auth(), firestore: fs);
      final threads = await svc.watchThreads().first;
      expect(threads, hasLength(25));
      expect(threads.first.otherUid, 'u29');
      expect(threads.last.otherUid, 'u5');
    });

    test('watchTotalUnread still counts past the 25-thread tier', () async {
      final fs = FakeFirebaseFirestore();
      final base = DateTime(2026, 1, 1);
      for (var i = 0; i < 30; i++) {
        await _thread(fs, 'u$i', base.add(Duration(hours: i)), unread: 2);
      }
      final svc = DmService(auth: _auth(), firestore: fs);
      expect(await svc.watchTotalUnread().first, 60);
    });

    test('fetchOlderThreads pages before a cursor', () async {
      final fs = FakeFirebaseFirestore();
      final base = DateTime(2026, 1, 1);
      for (var i = 0; i < 30; i++) {
        await _thread(fs, 'u$i', base.add(Duration(hours: i)));
      }
      final svc = DmService(auth: _auth(), firestore: fs);
      final live = await svc.watchThreads().first;
      expect(live, hasLength(25));
      final older = await svc.fetchOlderThreads(
        lastThreadId: live.last.threadId,
      );
      expect(older.map((t) => t.otherUid),
          ['u4', 'u3', 'u2', 'u1', 'u0']);
    });
  });

  group('MatchService batched names (design §3.2.2)', () {
    test('one miniProfiles call hydrates every match', () async {
      final fs = FakeFirebaseFirestore();
      await _match(fs, 'a', score: 0.9);
      await _match(fs, 'b', score: 0.7);
      await _match(fs, 'c', score: 0.8);
      final api = _CountingApi();
      final svc =
          MatchService(auth: _auth(), firestore: fs, api: api);
      final views = await svc.watchMutualMatches().first;
      expect(api.miniCalls, 1);
      expect(api.lastUids.toSet(), {'a', 'b', 'c'});
      expect(views.map((v) => v.otherName),
          ['Mini a', 'Mini c', 'Mini b']); // score order kept
    });

    test('backend failure falls back to profile docs, not blanks', () async {
      final fs = FakeFirebaseFirestore();
      await _match(fs, 'a');
      await fs.doc('users/a/profile/main').set({'name': 'Ann'});
      final svc = MatchService(
          auth: _auth(), firestore: fs, api: _FailingApi());
      final views = await svc.watchMutualMatches().first;
      expect(views.single.otherName, 'Ann');
    });

    test('watchMutualMatches is bounded to 25', () async {
      final fs = FakeFirebaseFirestore();
      for (var i = 0; i < 30; i++) {
        await _match(fs, 'u$i');
      }
      final svc = MatchService(
          auth: _auth(), firestore: fs, api: _CountingApi());
      expect(await svc.watchMutualMatches().first, hasLength(25));
    });
  });

  group('ApiClient.miniProfiles chunking', () {
    test('250 uids go out as 3 capped posts', () async {
      final sizes = <int>[];
      final client = ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((req) async {
          final uids =
              (jsonDecode(req.body) as Map)['uids'] as List;
          sizes.add(uids.length);
          return http.Response(
              jsonEncode({
                'profiles': {
                  for (final u in uids)
                    u as String: {'name': 'N-$u', 'photo': '', 'online': false},
                },
              }),
              200);
        }),
      );
      final out = await client.miniProfiles(
          [for (var i = 0; i < 250; i++) 'u$i']);
      expect(sizes, [100, 100, 50]);
      expect(out, hasLength(250));
      expect(out['u249']!.name, 'N-u249');
    });
  });

  testWidgets('messages archive appends older threads on scroll',
      (tester) async {
    final base = DateTime(2026, 1, 1);
    final live = [
      for (var i = 0; i < 25; i++)
        DmThread(
          threadId: 'u${i}__me',
          otherUid: 'u$i',
          lastMessageAt: base.add(Duration(hours: 100 - i)),
        ),
    ];
    final archive = [
      for (var i = 0; i < 5; i++)
        DmThread(
          threadId: 'old${i}__me',
          otherUid: 'old$i',
          lastMessageAt: base.add(Duration(hours: 70 - i)),
        ),
    ];
    final api = _CountingApi();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: MessagesScreen(
        dmService: _FakeDm(live: live, archive: archive),
        matchService: _FakeMatches(),
        apiClient: api,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Mini u0'), findsOneWidget);
    expect(find.text('Mini old0'), findsNothing);

    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Mini old4'), 600);
    await tester.pumpAndSettle();
    expect(find.text('Mini old4'), findsOneWidget);
  });
}

class _FakeDm extends DmService {
  _FakeDm({required List<DmThread> live, required List<DmThread> archive})
      : _live = live,
        _archive = archive,
        super(auth: _auth());

  final List<DmThread> _live;
  final List<DmThread> _archive;

  @override
  Stream<List<DmThread>> watchThreads({int limit = 25}) =>
      Stream.value(_live);

  @override
  Future<List<DmThread>> fetchOlderThreads({
    required String lastThreadId,
    int limit = 25,
  }) async =>
      _archive;
}

class _FakeMatches extends MatchService {
  _FakeMatches() : super(auth: _auth());
  @override
  Stream<List<MatchView>> watchMutualMatches({int limit = 25}) =>
      Stream.value(const []);
}
