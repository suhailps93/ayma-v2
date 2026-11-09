import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/plan_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/pending_chat_queue.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

Widget _app(ApiClient api) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => ChatScreen(
          apiClient: api,
          pendingQueue: PendingChatQueue(api: api, currentUid: () => null),
        ),
      ),
      GoRoute(
        path: PlanScreen.path,
        builder: (_, __) => const Scaffold(body: Text('PLANS PAGE')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

/// A chat screen whose /chat/stream requests are captured (decoded bodies)
/// and answered with a one-line reply.
(ApiClient, List<Map<String, dynamic>>) _capturingApi() {
  final bodies = <Map<String, dynamic>>[];
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') {
      return http.Response(
        jsonEncode({'messages': <dynamic>[], 'next_before': null}),
        200,
        headers: _jsonUtf8,
      );
    }
    if (request.url.path == '/chat/stream') {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      final body = [
        'data: ${jsonEncode({'type': 'reply', 'text': 'Reading it now.', 'tools_used': <String>[]})}',
        '',
        '',
      ].join('\n');
      return http.Response(
        body,
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
    }
    return http.Response('{}', 200, headers: _jsonUtf8);
  });
  return (
    ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true)),
    bodies,
  );
}

Future<void> _stageAndSend(
  WidgetTester tester,
  ChatKickoff kickoff, {
  String? text,
}) async {
  ChatInbox.instance.push(kickoff);
  await tester.pumpAndSettle();
  if (text != null) {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
  }
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets(
    'a staged web-research share sends the report REFERENCE, not content',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (api, bodies) = _capturingApi();
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();

      await _stageAndSend(
        tester,
        ChatKickoff.draftAbout(
          targetUid: 'u_self',
          label: 'Suhail Pallath Sulaiman',
          shareKind: 'deep_dive',
          refId: 'dive-123',
        ),
        text: 'what do y think',
      );

      expect(bodies, hasLength(1));
      final body = bodies.single;
      expect(body['message'], 'what do y think');
      expect(body['shared_kind'], 'deep_dive');
      expect(body['shared_ref_id'], 'dive-123');
      expect(body['shared_subject_uid'], 'u_self');
      expect(body['shared_subject_name'], 'Suhail Pallath Sulaiman');
      // The reference is all that travels: no report body anywhere in the
      // payload (the old bug dropped the context entirely; embedding the
      // whole report is the other failure this design rules out).
      expect(body.keys, isNot(contains('report')));
      expect(body.keys, isNot(contains('digest')));
    },
  );

  testWidgets(
    'a staged appearance share sends the reference and the opened run stamp',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (api, bodies) = _capturingApi();
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();

      await _stageAndSend(
        tester,
        ChatKickoff.draftAbout(
          targetUid: 'u_self',
          label: 'Your appearance report',
          shareKind: 'appearance',
          refId: 'u_self',
          refVersion: '2026-11-09T01:00:00+00:00',
        ),
        text: 'what do u think',
      );

      expect(bodies, hasLength(1));
      final body = bodies.single;
      expect(body['shared_kind'], 'appearance');
      expect(body['shared_ref_id'], 'u_self');
      expect(body['shared_subject_uid'], 'u_self');
      // The exact run he opened — a re-run since the share must not be
      // silently swapped in when Ayma pulls the report.
      expect(body['shared_ref_version'], '2026-11-09T01:00:00+00:00');
    },
  );

  testWidgets('sending the card alone still carries the reference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (api, bodies) = _capturingApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    // No typed text: the user's explicit tap on send posts the card alone.
    await _stageAndSend(
      tester,
      ChatKickoff.draftAbout(
        targetUid: 'u_self',
        label: 'Suhail Pallath Sulaiman',
        shareKind: 'deep_dive',
        refId: 'dive-123',
      ),
    );

    expect(bodies, hasLength(1));
    expect(bodies.single['shared_kind'], 'deep_dive');
    expect(bodies.single['shared_ref_id'], 'dive-123');
  });

  testWidgets(
    'a staged profile share keeps the old path — no shared reference',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (api, bodies) = _capturingApi();
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();

      await _stageAndSend(
        tester,
        ChatKickoff.draftAbout(
          targetUid: 'u_dana',
          label: 'Dana',
          shareKind: 'profile',
        ),
        text: 'what do y think',
      );

      expect(bodies, hasLength(1));
      final body = bodies.single;
      // Profiles resolve through the viewing briefing (founder-confirmed
      // working) — untouched by the reference change.
      expect(body['viewing_profile_uid'], 'u_dana');
      expect(body['shared_kind'], '');
      expect(body['shared_ref_id'], '');
    },
  );

  testWidgets('a plain message carries no shared reference', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (api, bodies) = _capturingApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'hey ayma');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(bodies, hasLength(1));
    expect(bodies.single['shared_kind'], '');
    expect(bodies.single['shared_ref_id'], '');
    expect(bodies.single['shared_ref_version'], '');
  });
}
