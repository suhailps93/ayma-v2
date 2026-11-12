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

MockFirebaseAuth _authAs(String uid) =>
    MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: uid));

/// A stub ApiClient whose /profiles/mini returns no profiles.
ApiClient _api() => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/profiles/mini') {
          return http.Response(jsonEncode({'profiles': {}}), 200);
        }
        return http.Response('{}', 200);
      }),
    );

final _t0 = DateTime(2026, 11, 7, 10, 0);
DateTime _at(int minutes) => _t0.add(Duration(minutes: minutes));

void main() {
  group('dmReceiptState derivation', () {
    test('no watermarks yet: sent', () {
      expect(
        dmReceiptState(messageCreatedAt: _at(5), deliveredAt: null, readAt: null),
        DmReceiptState.sent,
      );
    });

    test('an unstamped (not yet server-saved) message is only ever sent',
        () {
      expect(
        dmReceiptState(
          messageCreatedAt: null,
          deliveredAt: _at(50),
          readAt: _at(60),
        ),
        DmReceiptState.sent,
      );
    });

    test('message newer than the delivered watermark: sent (recipient was '
        'offline when it was sent)', () {
      expect(
        dmReceiptState(
          messageCreatedAt: _at(30),
          deliveredAt: _at(10),
          readAt: null,
        ),
        DmReceiptState.sent,
      );
    });

    test('message at or before the delivered watermark: delivered', () {
      expect(
        dmReceiptState(
          messageCreatedAt: _at(5),
          deliveredAt: _at(5),
          readAt: null,
        ),
        DmReceiptState.delivered,
      );
      expect(
        dmReceiptState(
          messageCreatedAt: _at(5),
          deliveredAt: _at(9),
          readAt: _at(2),
        ),
        DmReceiptState.delivered,
      );
    });

    test('message at or before the read watermark: read', () {
      expect(
        dmReceiptState(
          messageCreatedAt: _at(5),
          deliveredAt: _at(6),
          readAt: _at(5),
        ),
        DmReceiptState.read,
      );
    });

    test('a read watermark ahead of the delivered one still shows read — '
        'the state never regresses', () {
      expect(
        dmReceiptState(
          messageCreatedAt: _at(30),
          deliveredAt: _at(10), // delivered cursor lags behind
          readAt: _at(40),
        ),
        DmReceiptState.read,
      );
    });

    test('one message walks sent -> delivered -> read as the watermarks '
        'advance', () {
      final created = _at(5);
      expect(
        dmReceiptState(messageCreatedAt: created, deliveredAt: null, readAt: null),
        DmReceiptState.sent,
      );
      expect(
        dmReceiptState(
          messageCreatedAt: created,
          deliveredAt: _at(6),
          readAt: null,
        ),
        DmReceiptState.delivered,
      );
      expect(
        dmReceiptState(
          messageCreatedAt: created,
          deliveredAt: _at(6),
          readAt: _at(7),
        ),
        DmReceiptState.read,
      );
    });

    test('DmReceiptWatermarks.stateFor matches the pure derivation', () {
      final w = DmReceiptWatermarks(
        otherDeliveredAt: _at(10),
        otherReadAt: _at(20),
      );
      expect(w.stateFor(_at(30)), DmReceiptState.sent);
      // At or before the read watermark is read — it covers the delivered
      // range too.
      expect(w.stateFor(_at(15)), DmReceiptState.read);
      expect(w.stateFor(_at(10)), DmReceiptState.read);
      // A pair whose read watermark lags its delivered one shows the pure
      // delivered state in between.
      final deliveredOnly = DmReceiptWatermarks(
        otherDeliveredAt: _at(10),
        otherReadAt: _at(2),
      );
      expect(deliveredOnly.stateFor(_at(5)), DmReceiptState.delivered);
      expect(deliveredOnly.stateFor(_at(1)), DmReceiptState.read);
      expect(DmReceiptWatermarks.none.stateFor(_at(0)), DmReceiptState.sent);
    });
  });

  group('DmService receipt watermarks (fake Firestore)', () {
    Future<FakeFirebaseFirestore> seeded() async {
      final fs = FakeFirebaseFirestore();
      await fs.doc('dm_threads/a__me').set({
        'participants': ['a', 'me'],
        'last_message_at': Timestamp.fromDate(_at(0)),
        'last_read_at': <String, dynamic>{
          'a': Timestamp.fromDate(_at(20)),
        },
        'last_delivered_at': <String, dynamic>{
          'a': Timestamp.fromDate(_at(10)),
          'me': Timestamp.fromDate(_at(3)),
        },
        'unread': <String, dynamic>{'me': 0, 'a': 0},
      });
      return fs;
    }

    test('thread list parsing exposes both sides of the watermarks',
        () async {
      final fs = await seeded();
      final svc = DmService(auth: _authAs('me'), firestore: fs);
      final threads = await svc.watchThreads().first;
      expect(threads, hasLength(1));
      final t = threads.single;
      expect(t.otherLastReadAt, _at(20));
      expect(t.otherLastDeliveredAt, _at(10));
      expect(t.myLastDeliveredAt, _at(3));
    });

    test('watchReceiptWatermarks reads the other side and follows updates',
        () async {
      final fs = await seeded();
      final svc = DmService(auth: _authAs('me'), firestore: fs);
      final first = await svc.watchReceiptWatermarks('a__me').first;
      expect(first.otherDeliveredAt, _at(10));
      expect(first.otherReadAt, _at(20));

      await fs.doc('dm_threads/a__me').update({
        'last_read_at.a': Timestamp.fromDate(_at(30)),
      });
      final next = await svc.watchReceiptWatermarks('a__me').first;
      expect(next.otherReadAt, _at(30));
      expect(next.stateFor(_at(25)), DmReceiptState.read);
    });

    test('watchReceiptWatermarks on a missing thread reads as no watermarks',
        () async {
      final svc = DmService(
        auth: _authAs('me'),
        firestore: FakeFirebaseFirestore(),
      );
      final w = await svc.watchReceiptWatermarks('a__me').first;
      expect(w.otherReadAt, isNull);
      expect(w.otherDeliveredAt, isNull);
      expect(w.stateFor(_at(0)), DmReceiptState.sent);
    });

    test('markThreadDelivered stamps only my entry — and the other side '
        'sees the tick move', () async {
      final fs = await seeded();
      final mine = DmService(auth: _authAs('me'), firestore: fs);
      final before = (await fs.doc('dm_threads/a__me').get()).data()!;
      expect((before['last_delivered_at'] as Map)['me'], isNotNull);

      await mine.markThreadDelivered('a__me');
      final after = (await fs.doc('dm_threads/a__me').get()).data()!;
      final delivered = after['last_delivered_at'] as Map;
      expect(delivered['me'], isNotNull);
      // Their entries and the read map are untouched.
      expect((delivered['a'] as Timestamp).toDate(), _at(10));
      expect(((after['last_read_at'] as Map)['a'] as Timestamp).toDate(),
          _at(20));

      // From the other phone: my watermark now covers a fresh message.
      final theirs = DmService(auth: _authAs('a'), firestore: fs);
      final w = await theirs.watchReceiptWatermarks('a__me').first;
      expect(w.otherDeliveredAt, isNotNull);
      expect(w.stateFor(DateTime.now().subtract(const Duration(minutes: 1))),
          DmReceiptState.delivered);
    });

    test('markThreadDelivered on a missing thread is a no-op', () async {
      final svc = DmService(
        auth: _authAs('me'),
        firestore: FakeFirebaseFirestore(),
      );
      await svc.markThreadDelivered('a__me');
    });
  });

  group('DmReceiptTicks widget', () {
    Future<Icon> pumpTicks(WidgetTester tester, DmReceiptState state) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DmReceiptTicks(state: state, color: Colors.grey.shade600),
          ),
        ),
      );
      return tester.widget<Icon>(find.byType(Icon));
    }

    testWidgets('sent shows a single tick in the resting colour',
        (tester) async {
      final icon = await pumpTicks(tester, DmReceiptState.sent);
      expect(icon.icon, Icons.done);
      expect(icon.color, Colors.grey.shade600);
      expect(find.bySemanticsLabel('Sent'), findsOneWidget);
    });

    testWidgets('delivered shows two ticks in the resting colour',
        (tester) async {
      final icon = await pumpTicks(tester, DmReceiptState.delivered);
      expect(icon.icon, Icons.done_all);
      expect(icon.color, Colors.grey.shade600);
      expect(find.bySemanticsLabel('Delivered'), findsOneWidget);
    });

    testWidgets('read shows two ticks in WhatsApp blue', (tester) async {
      final icon = await pumpTicks(tester, DmReceiptState.read);
      expect(icon.icon, Icons.done_all);
      expect(icon.color, DmReceiptTicks.readColor);
      expect(find.bySemanticsLabel('Read'), findsOneWidget);
    });
  });

  group('DmThreadScreen receipts', () {
    testWidgets(
        'my ticks follow the watermarks live: sent, delivered, blue read',
        (tester) async {
      final fresh =
          StreamController<FreshData<List<DmMessage>>>.broadcast();
      final receipts = StreamController<DmReceiptWatermarks>.broadcast();
      final dm = _FakeDm(fresh, receipts);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(
            threadId: 'a__me',
            dmService: dm,
            apiClient: _api(),
          ),
        ),
      );
      await tester.pump();
      fresh.add(
        FreshData(
          data: [
            DmMessage(
              id: 'm1',
              senderUid: 'me',
              type: 'text',
              body: 'hello there',
              createdAt: _at(5),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      // No watermarks yet: a single tick.
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsNothing);

      // Their device syncs the thread: two ticks.
      receipts.add(DmReceiptWatermarks(otherDeliveredAt: _at(10)));
      await tester.pump();
      expect(find.byIcon(Icons.done_all), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.done_all)).color,
        isNot(DmReceiptTicks.readColor),
      );

      // They read it: two blue ticks.
      receipts.add(
        DmReceiptWatermarks(otherDeliveredAt: _at(10), otherReadAt: _at(20)),
      );
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.done_all)).color,
        DmReceiptTicks.readColor,
      );
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
        'incoming messages mark delivered only once server-confirmed, '
        'never from cache', (tester) async {
      final fresh =
          StreamController<FreshData<List<DmMessage>>>.broadcast();
      final receipts = StreamController<DmReceiptWatermarks>.broadcast();
      final dm = _FakeDm(fresh, receipts);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(
            threadId: 'a__me',
            dmService: dm,
            apiClient: _api(),
          ),
        ),
      );
      await tester.pump();
      final incoming = DmMessage(
        id: 'i1',
        senderUid: 'a',
        type: 'text',
        body: 'hi back',
        createdAt: _at(6),
      );
      fresh.add(FreshData(data: [incoming], isFromCache: true));
      await tester.pump();
      await tester.pump();
      expect(dm.deliveredMarks, isEmpty);

      fresh.add(FreshData(data: [incoming]));
      await tester.pump();
      await tester.pump();
      expect(dm.deliveredMarks, ['a__me']);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

/// A DmService stub for the thread screen: messages + receipt watermarks
/// come from test controllers, delivery marks are recorded.
class _FakeDm extends DmService {
  _FakeDm(this._fresh, this._receipts)
      : super(auth: _authAs('me'));

  final StreamController<FreshData<List<DmMessage>>> _fresh;
  final StreamController<DmReceiptWatermarks> _receipts;
  final List<String> deliveredMarks = [];

  @override
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(
    String threadId, {
    int limit = 30,
  }) =>
      _fresh.stream;

  @override
  Stream<DmReceiptWatermarks> watchReceiptWatermarks(String threadId) =>
      _receipts.stream;

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<void> markThreadDelivered(String threadId) async {
    deliveredMarks.add(threadId);
  }

  @override
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) async =>
      DmAssist.empty;
}
