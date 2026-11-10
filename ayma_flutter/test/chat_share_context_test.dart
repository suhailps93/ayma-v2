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

  _cardSendTests();
  _cardHistoryTests();
  _cardModelTests();
}

// ---------------------------------------------------------------------------
// Shared-card persistence (founder bug 2026-11-09): a Send-to-Ayma card
// showed in the live chat but was gone after closing and reopening the
// app — the card's identity lived only in the client's in-memory turn.
// The send now carries the card (shared_card_*) so the server persists it
// on the user turn, and history rows rebuild the same tappable card.

/// A chat screen whose /chat/history serves [rows] (and [olderRows] for a
/// `before` page when given), recording every `before` cursor requested.
(ApiClient, List<String?>) _historyApi(
  List<Map<String, dynamic>> rows, {
  List<Map<String, dynamic>>? olderRows,
}) {
  final befores = <String?>[];
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') {
      final before = request.url.queryParameters['before'];
      befores.add(before);
      if (before != null && olderRows != null) {
        return http.Response(
          jsonEncode({'messages': olderRows, 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response(
        jsonEncode({
          'messages': rows,
          'next_before': olderRows != null ? 'cursor-older' : null,
        }),
        200,
        headers: _jsonUtf8,
      );
    }
    if (request.url.path == '/chat/stream') {
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
    befores,
  );
}

Widget _historyApp(ApiClient api) {
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
      GoRoute(
        path: '/deep-dive/:id',
        builder: (_, s) =>
            Scaffold(body: Text('DIVE PAGE ${s.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/profile/user/:uid',
        builder: (_, s) =>
            Scaffold(body: Text('PROFILE PAGE ${s.pathParameters['uid']}')),
      ),
      GoRoute(
        path: '/appearance/:id',
        builder: (_, __) => const Scaffold(body: Text('APPEARANCE PAGE')),
      ),
      GoRoute(
        path: '/match/:id',
        builder: (_, __) => const Scaffold(body: Text('MATCH PAGE')),
      ),
      GoRoute(
        path: '/profile/wiki',
        builder: (_, __) => const Scaffold(body: Text('STORY PAGE')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

Map<String, dynamic> _cardRow({
  required String kind,
  required String uid,
  required String name,
  String photo = '',
  String refId = '',
  String text = 'what do y think',
}) => {
      'role': 'user',
      'text': text,
      'image_path': '',
      'image_url': '',
      'audio_path': '',
      'audio_url': '',
      'tools': <String>[],
      'subject_image': '',
      'created_at': '2026-11-09T08:00:00.000Z',
      'client_msg_id': '',
      'shared_card_kind': kind,
      'shared_card_uid': uid,
      'shared_card_name': name,
      'shared_card_photo': photo,
      'shared_card_ref_id': refId,
    };

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The send-side half of the round trip: posting a card sends its
/// identity as shared_card_* (for EVERY kind — profiles included, whose
/// shared_* tool reference stays empty), and a plain message sends none.
void _cardSendTests() {
  testWidgets('a staged profile share sends the card identity', (
    tester,
  ) async {
    _bigView(tester);
    final (api, bodies) = _capturingApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await _stageAndSend(
      tester,
      ChatKickoff.draftAbout(
        targetUid: 'u_dana',
        label: 'Dana',
        shareKind: 'profile',
        photoUrl: 'https://example.com/dana.jpg',
      ),
      text: 'what do y think',
    );

    expect(bodies, hasLength(1));
    final body = bodies.single;
    expect(body['shared_card_kind'], 'profile');
    expect(body['shared_card_uid'], 'u_dana');
    expect(body['shared_card_name'], 'Dana');
    expect(body['shared_card_photo'], 'https://example.com/dana.jpg');
    expect(body['shared_card_ref_id'], '');
    // The tool reference stays profile-free, exactly as before.
    expect(body['shared_kind'], '');
  });

  testWidgets('a staged web-research share sends the card identity too', (
    tester,
  ) async {
    _bigView(tester);
    final (api, bodies) = _capturingApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await _stageAndSend(
      tester,
      ChatKickoff.draftAbout(
        targetUid: 'u_dana',
        label: 'Dana',
        shareKind: 'deep_dive',
        photoUrl: 'https://example.com/dana.jpg',
        refId: 'dive-123',
      ),
      text: 'what do y think',
    );

    expect(bodies, hasLength(1));
    final body = bodies.single;
    expect(body['shared_card_kind'], 'deep_dive');
    expect(body['shared_card_uid'], 'u_dana');
    expect(body['shared_card_name'], 'Dana');
    expect(body['shared_card_photo'], 'https://example.com/dana.jpg');
    expect(body['shared_card_ref_id'], 'dive-123');
  });

  testWidgets('the card alone still carries the card identity', (
    tester,
  ) async {
    _bigView(tester);
    final (api, bodies) = _capturingApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await _stageAndSend(
      tester,
      ChatKickoff.draftAbout(
        targetUid: 'u_dana',
        label: 'Dana',
        shareKind: 'match',
        photoUrl: 'https://example.com/dana.jpg',
        refId: 'm-1',
      ),
    );

    expect(bodies, hasLength(1));
    expect(bodies.single['shared_card_kind'], 'match');
    expect(bodies.single['shared_card_ref_id'], 'm-1');
  });

  testWidgets('a plain message carries no card identity', (tester) async {
    _bigView(tester);
    final (api, bodies) = _capturingApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'hey ayma');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(bodies, hasLength(1));
    expect(bodies.single['shared_card_kind'], '');
    expect(bodies.single['shared_card_uid'], '');
    expect(bodies.single['shared_card_name'], '');
    expect(bodies.single['shared_card_photo'], '');
    expect(bodies.single['shared_card_ref_id'], '');
  });
}

/// The history half: a stored row carrying the card rebuilds the same
/// card in the transcript after a restart — one test per kind.
void _cardHistoryTests() {
  Future<void> expectCard(
    WidgetTester tester,
    Map<String, dynamic> row, {
    required String label,
    required String kindLabel,
  }) async {
    _bigView(tester);
    final (api, _) = _historyApi([row]);
    await tester.pumpWidget(_historyApp(api));
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget);
    expect(find.text(kindLabel), findsOneWidget);
  }

  testWidgets('history rebuilds a profile card', (tester) async {
    await expectCard(
      tester,
      _cardRow(kind: 'profile', uid: 'u_dana', name: 'Dana'),
      label: 'Dana',
      kindLabel: 'PROFILE · TAP TO OPEN',
    );
  });

  testWidgets('history rebuilds a web-research card', (tester) async {
    await expectCard(
      tester,
      _cardRow(
        kind: 'deep_dive',
        uid: 'u_dana',
        name: 'Dana',
        refId: 'dive-123',
      ),
      label: 'Web research on Dana',
      kindLabel: 'WEB FINDING · TAP TO OPEN',
    );
  });

  testWidgets('history rebuilds an appearance card', (tester) async {
    await expectCard(
      tester,
      _cardRow(
        kind: 'appearance',
        uid: 'u_self',
        name: 'Your appearance report',
        refId: 'u_self',
      ),
      label: 'Your appearance report',
      kindLabel: 'APPEARANCE REPORT · TAP TO OPEN',
    );
  });

  testWidgets('history rebuilds a match card', (tester) async {
    await expectCard(
      tester,
      _cardRow(kind: 'match', uid: 'u_dana', name: 'Dana', refId: 'm-1'),
      label: 'Dana · match report',
      kindLabel: 'MATCH REPORT · TAP TO OPEN',
    );
  });

  testWidgets('history rebuilds a story card', (tester) async {
    await expectCard(
      tester,
      _cardRow(kind: 'story', uid: 'u_self', name: 'Your Story'),
      label: 'Your Story',
      kindLabel: 'STORY · TAP TO OPEN',
    );
  });

  testWidgets('a rebuilt web-research card opens the shared report', (
    tester,
  ) async {
    _bigView(tester);
    final (api, _) = _historyApi([
      _cardRow(
        kind: 'deep_dive',
        uid: 'u_dana',
        name: 'Dana',
        refId: 'dive-123',
      ),
    ]);
    await tester.pumpWidget(_historyApp(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Web research on Dana'));
    await tester.pumpAndSettle();
    expect(find.text('DIVE PAGE dive-123'), findsOneWidget);
  });

  testWidgets('a rebuilt profile card opens the shared profile', (
    tester,
  ) async {
    _bigView(tester);
    final (api, _) = _historyApi([
      _cardRow(kind: 'profile', uid: 'u_dana', name: 'Dana'),
    ]);
    await tester.pumpWidget(_historyApp(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dana'));
    await tester.pumpAndSettle();
    expect(find.text('PROFILE PAGE u_dana'), findsOneWidget);
  });

  testWidgets('a card-alone history row shows the card, not the label', (
    tester,
  ) async {
    _bigView(tester);
    final (api, _) = _historyApi([
      _cardRow(
        kind: 'deep_dive',
        uid: 'u_dana',
        name: 'Dana',
        refId: 'dive-123',
        text: '[shared deep dive]',
      ),
    ]);
    await tester.pumpWidget(_historyApp(api));
    await tester.pumpAndSettle();

    expect(find.text('Web research on Dana'), findsOneWidget);
    // The persisted wire fallback label is not a message the user wrote —
    // it must not render as a bubble under the card.
    expect(find.text('[shared deep dive]'), findsNothing);
  });

  testWidgets('an older history page rebuilds its cards too', (
    tester,
  ) async {
    _bigView(tester);
    final filler = [
      for (var i = 0; i < 30; i++)
        {
          'role': i.isEven ? 'user' : 'ayma',
          'text': 'filler message $i',
          'image_path': '',
          'image_url': '',
          'audio_path': '',
          'audio_url': '',
          'tools': <String>[],
          'subject_image': '',
          'created_at': '2026-11-09T08:00:00.000Z',
          'client_msg_id': '',
        },
    ];
    final (api, befores) = _historyApi(
      filler,
      olderRows: [
        _cardRow(
          kind: 'deep_dive',
          uid: 'u_dana',
          name: 'Dana',
          refId: 'dive-123',
        ),
      ],
    );
    await tester.pumpWidget(_historyApp(api));
    await tester.pumpAndSettle();

    // Scroll toward the older end until the next page is fetched AND the
    // prepended card is laid out. The second clause keeps flinging past the
    // fetch so the just-loaded card lands inside the ListView's cacheExtent
    // regardless of card height (the shared-ref card's exact height is not
    // what this test pins).
    for (var i = 0;
        i < 16 &&
            (!befores.contains('cursor-older') ||
                find.text('Web research on Dana').evaluate().isEmpty);
        i++) {
      await tester.fling(
        find.byType(ListView),
        const Offset(0, 600),
        2000,
      );
      await tester.pumpAndSettle();
    }
    expect(befores, contains('cursor-older'));
    expect(find.text('Web research on Dana'), findsOneWidget);
    expect(find.text('WEB FINDING · TAP TO OPEN'), findsOneWidget);
  });
}

void _cardModelTests() {
  test('ChatMessage carries the card through fromMap and toMap', () {
    final m = ChatMessage.fromMap({
      'role': 'user',
      'text': 'what do y think',
      'shared_card_kind': 'appearance',
      'shared_card_uid': 'u_self',
      'shared_card_name': 'Your appearance report',
      'shared_card_photo': 'https://example.com/me.jpg',
      'shared_card_ref_id': 'u_self',
    });
    expect(m.sharedCardKind, 'appearance');
    expect(m.sharedCardUid, 'u_self');
    expect(m.sharedCardName, 'Your appearance report');
    expect(m.sharedCardPhoto, 'https://example.com/me.jpg');
    expect(m.sharedCardRefId, 'u_self');

    // The last-known cache round trip (toMap → fromMap) keeps the card.
    final back = ChatMessage.fromMap(m.toMap());
    expect(back.sharedCardKind, 'appearance');
    expect(back.sharedCardUid, 'u_self');
    expect(back.sharedCardName, 'Your appearance report');
    expect(back.sharedCardPhoto, 'https://example.com/me.jpg');
    expect(back.sharedCardRefId, 'u_self');
  });
}
