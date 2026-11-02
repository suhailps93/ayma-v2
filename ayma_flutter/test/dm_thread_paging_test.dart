import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MockFirebaseAuth _auth() =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));

final _base = DateTime(2026, 1, 1);

Future<void> _seedMessages(FakeFirebaseFirestore fs, int n) async {
  final col = fs.collection('dm_threads/t__me/messages');
  for (var i = 0; i < n; i++) {
    await col.doc('m$i').set({
      'sender_uid': i.isEven ? 't' : 'me',
      'type': 'text',
      'body': 'msg$i',
      'created_at': Timestamp.fromDate(_base.add(Duration(minutes: i))),
    });
  }
}

DmMessage _msg(int i) => DmMessage(
      id: 'm$i',
      senderUid: i.isEven ? 't' : 'me',
      type: 'text',
      body: 'msg$i',
      createdAt: _base.add(Duration(minutes: i)),
    );

ApiClient _api() => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/profiles/mini') {
          return http.Response(jsonEncode({'profiles': {}}), 200);
        }
        return http.Response('{}', 200);
      }),
    );

class _PagingDm extends DmService {
  _PagingDm(this._tail, this._pages) : super(auth: _auth());

  final List<DmMessage> _tail;
  final Map<String, List<DmMessage>> _pages;
  final List<String> anchors = [];

  @override
  Stream<List<DmMessage>> watchMessages(String threadId,
          {int limit = 30}) =>
      Stream.value(_tail);

  @override
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(String threadId,
          {int limit = 30}) =>
      Stream.value(FreshData(data: _tail));

  @override
  Future<List<DmMessage>> fetchOlderMessages(
    String threadId, {
    required String lastMessageId,
    int limit = 30,
  }) async {
    anchors.add(lastMessageId);
    return _pages[lastMessageId] ?? const [];
  }

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) async =>
      DmAssist.empty;
}

void main() {
  group('DmService message windowing (design §3.3)', () {
    test('watchMessages streams only the newest 30, oldest-first', () async {
      final fs = FakeFirebaseFirestore();
      await _seedMessages(fs, 100);
      final svc = DmService(auth: _auth(), firestore: fs);
      final tail = await svc.watchMessages('t__me').first;
      expect(tail, hasLength(30));
      expect(tail.first.id, 'm70');
      expect(tail.last.id, 'm99');
    });

    test('fetchOlderMessages walks history to exhaustion', () async {
      final fs = FakeFirebaseFirestore();
      await _seedMessages(fs, 100);
      final svc = DmService(auth: _auth(), firestore: fs);
      final seen = <String>[];
      var anchor = (await svc.watchMessages('t__me').first).first.id;
      seen.addAll(
          (await svc.watchMessages('t__me').first).map((m) => m.id));
      for (var i = 0; i < 5; i++) {
        final page = await svc.fetchOlderMessages('t__me',
            lastMessageId: anchor);
        if (page.isEmpty) break;
        expect(page.map((m) => m.id).toSet().intersection(seen.toSet()), isEmpty);
        seen.addAll(page.map((m) => m.id));
        anchor = page.first.id;
        if (page.length < 30) break;
      }
      expect(seen, hasLength(100));
    });
  });

  testWidgets('a 100-message thread opens on the tail and pages history up',
      (tester) async {
    final tail = [for (var i = 70; i < 100; i++) _msg(i)];
    final older = [for (var i = 40; i < 70; i++) _msg(i)];
    final dm = _PagingDm(tail, {'m70': older});
    await tester.pumpWidget(MaterialApp(
      home: DmThreadScreen(
        threadId: 't__me',
        dmService: dm,
        apiClient: _api(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(dm.anchors, isEmpty); // no history fetch on open
    expect(find.text('msg99'), findsOneWidget); // newest visible
    expect(find.text('msg40'), findsNothing); // history not loaded

    final transcript = find.byWidgetPredicate(
        (w) => w is ListView && w.reverse == true);
    // Scroll up until the older page arrives.
    for (var i = 0;
        i < 12 && find.text('msg40').evaluate().isEmpty;
        i++) {
      await tester.drag(transcript, const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(dm.anchors.first, 'm70'); // anchored on the oldest tail message
    expect(find.text('msg40'), findsOneWidget); // older page prepended

    // The tail survives underneath: scroll back down to the newest.
    for (var i = 0;
        i < 12 && find.text('msg99').evaluate().isEmpty;
        i++) {
      await tester.drag(transcript, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('msg99'), findsOneWidget);
  });
}
