import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/util/perf_log.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    PerfLog.resetForTest();
  });

  tearDown(() {
    PerfLog.resetForTest();
  });

  test('PerfLog logs app start and milestone with elapsed milliseconds', () {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    PerfLog.start();
    expect(logs.length, 1);
    expect(logs.first, contains('[PerfLog] [app_start] timer initialized'));

    PerfLog.milestone('Firebase init complete');
    expect(logs.length, 2);
    expect(logs[1], contains('[PerfLog] [milestone] Firebase init complete (+'));
    expect(logs[1], contains('ms)'));
  });

  test('PerfLog milestone auto-starts timer if not started yet', () {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    PerfLog.milestone('Backend bootstrap complete');
    expect(logs.any((l) => l.contains('[app_start] timer initialized')), isTrue);
    expect(logs.any((l) => l.contains('[milestone] Backend bootstrap complete')), isTrue);
  });

  testWidgets('PerfLog trackFirstFrame logs after frame rendered', (tester) async {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    PerfLog.trackFirstFrame();
    expect(logs.any((l) => l.contains('First frame rendered')), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(logs.any((l) => l.contains('[milestone] First frame rendered (+')), isTrue);
  });

  test('PerfLog apiCall logs method, path, status, success and duration', () {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    PerfLog.apiCall(
      method: 'POST',
      uri: Uri.parse('https://example.com/bootstrap'),
      statusCode: 200,
      durationMs: 120,
      success: true,
    );
    expect(logs.length, 1);
    expect(logs.first, '[PerfLog] [api] POST /bootstrap -> 200 (SUCCESS) in 120ms');

    PerfLog.apiCall(
      method: 'GET',
      uri: Uri.parse('https://example.com/usage?period=all'),
      statusCode: null,
      durationMs: 45,
      success: false,
      error: 'SocketException: Connection refused',
    );
    expect(logs.length, 2);
    expect(logs[1], contains('[PerfLog] [api] GET /usage?period=all -> ERROR (FAILED) in 45ms (SocketException: Connection refused)'));
  });

  test('PerfLog firestoreSnapshot logs source, pending writes, and doc count', () {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    PerfLog.firestoreSnapshot(
      path: 'users/123/profile/main',
      isFromCache: true,
      hasPendingWrites: true,
    );
    expect(logs.length, 1);
    expect(logs.first, '[PerfLog] [firestore] users/123/profile/main snapshot from CACHE [pending writes]');

    PerfLog.firestoreSnapshot(
      path: 'dm_threads',
      isFromCache: false,
      hasPendingWrites: false,
      docCount: 5,
    );
    expect(logs.length, 2);
    expect(logs[1], '[PerfLog] [firestore] dm_threads snapshot from SERVER (5 docs)');
  });

  test('ApiClient request timing is logged via PerfLog on success', () async {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    final mockHttp = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'session_mode': 'marketing',
          'livekit': {'token': 't', 'url': 'wss://x', 'room': 'r'},
        }),
        200,
      );
    });

    final client = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );

    final res = await client.bootstrap(sessionId: 's1');
    expect(res.sessionMode, 'marketing');

    final apiLogs = logs.where((l) => l.contains('[PerfLog] [api]')).toList();
    expect(apiLogs.length, 1);
    expect(apiLogs.first, contains('POST /bootstrap -> 200 (SUCCESS) in '));
  });

  test('ApiClient request timing is logged via PerfLog on network failure', () async {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    final mockHttp = MockClient((request) async {
      throw http.ClientException('Simulated network failure');
    });

    final client = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );

    await expectLater(
      client.bootstrap(sessionId: 's1'),
      throwsA(isA<ApiException>()),
    );

    final apiLogs = logs.where((l) => l.contains('[PerfLog] [api]')).toList();
    expect(apiLogs.length, 1);
    expect(apiLogs.first, contains('POST /bootstrap -> ERROR (FAILED) in '));
    expect(apiLogs.first, contains('Simulated network failure'));
  });

  test('ProfileService.watchProfile logs snapshot origin', () async {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    final fakeFirestore = FakeFirebaseFirestore();
    final auth = MockFirebaseAuth(signedIn: true);
    final service = ProfileService(auth: auth, firestore: fakeFirestore);

    await fakeFirestore.doc('users/${auth.currentUser!.uid}/profile/main').set({
      'name': 'Jordan',
      'gender': 'Woman',
    });

    final stream = service.watchProfile();
    final first = await stream.first;
    expect(first?.name, 'Jordan');

    final fsLogs = logs.where((l) => l.contains('[PerfLog] [firestore]')).toList();
    expect(fsLogs.length, greaterThanOrEqualTo(1));
    expect(fsLogs.first, contains('users/${auth.currentUser!.uid}/profile/main snapshot from '));
  });

  test('DmService.watchThreads logs snapshot origin and doc count', () async {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    final fakeFirestore = FakeFirebaseFirestore();
    final auth = MockFirebaseAuth(signedIn: true);
    final service = DmService(auth: auth, firestore: fakeFirestore);

    await fakeFirestore.collection('dm_threads').doc('thread_1').set({
      'participants': [auth.currentUser!.uid, 'other_uid'],
      'hidden_for': <String>[],
    });

    final stream = service.watchThreads();
    final first = await stream.first;
    expect(first.length, 1);

    final fsLogs = logs.where((l) => l.contains('[PerfLog] [firestore] dm_threads snapshot')).toList();
    expect(fsLogs.length, 1);
    expect(fsLogs.first, contains('dm_threads snapshot from '));
    expect(fsLogs.first, contains('(1 docs)'));
  });

  test('NotificationService.watch logs snapshot origin and doc count', () async {
    final logs = <String>[];
    PerfLog.customLogger = logs.add;

    final fakeFirestore = FakeFirebaseFirestore();
    final auth = MockFirebaseAuth(signedIn: true);
    final service = NotificationService(auth: auth, firestore: fakeFirestore);

    await fakeFirestore.collection('users/${auth.currentUser!.uid}/notifications').doc('notif_1').set({
      'type': 'new_scored_match',
      'body': 'Match available',
      'dismissed': false,
      'read': false,
    });

    final stream = service.watch();
    final first = await stream.first;
    expect(first.length, 1);

    final fsLogs = logs.where((l) => l.contains('[PerfLog] [firestore] users/${auth.currentUser!.uid}/notifications snapshot')).toList();
    expect(fsLogs.length, 1);
    expect(fsLogs.first, contains('(1 docs)'));
  });
}
