import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/plans_screen.dart';
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
        // A fresh queue per app: the app-wide one would carry a message held
        // for credits by one test into the next.
        builder: (_, __) => ChatScreen(
          apiClient: api,
          pendingQueue: PendingChatQueue(api: api, currentUid: () => null),
        ),
      ),
      GoRoute(
        path: PlansScreen.path,
        builder: (_, __) => const Scaffold(body: Text('PLANS PAGE')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets(
      'a persisted Ayma turn renders its tool label as a visible kicker',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({
            'messages': [
              {'role': 'user', 'text': 'that last reply was great'},
              {
                'role': 'ayma',
                'text': 'Noted — thank you for telling me.',
                'tools': ['Noted your feedback'],
              },
            ],
            'next_before': null,
          }),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text('Noted your feedback'), findsOneWidget);
  });

  testWidgets(
      'the streamed path shows the tool kicker on the resolved reply',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final hits = <String>[];
    final mockHttp = MockClient((request) async {
      hits.add('${request.method} ${request.url.path}');
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: _jsonUtf8);
      }
      if (request.url.path == '/chat/stream') {
        final body = [
          'data: ${jsonEncode({
                'type': 'status',
                'label': 'Making a note of your feedback…'
              })}',
          '',
          'data: ${jsonEncode({
                'type': 'reply',
                'text': 'Noted — thanks for the feedback.',
                'tools_used': ['Noted your feedback'],
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).last, 'that reply nailed it');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(hits, contains('POST /chat/stream'));
    expect(find.text('Noted your feedback'), findsOneWidget);
    expect(find.text('Noted — thanks for the feedback.'), findsOneWidget);
  });

  testWidgets(
      'an out-of-credits reply renders a Get credits button that opens the plans page',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: _jsonUtf8);
      }
      if (request.url.path == '/chat/stream') {
        final body = [
          'data: ${jsonEncode({
                'type': 'reply',
                'text': "I'm out of credits right now.",
                'tools_used': <String>[],
                'usage_capped': true,
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'hey ayma');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Get credits'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);

    await tester.tap(find.text('Get credits'));
    await tester.pumpAndSettle();

    expect(find.text('PLANS PAGE'), findsOneWidget);
  });

  testWidgets(
      'a capped Ayma reply renders its message as one normal paragraph, '
      'not one character per line', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const message = "I'm out of credits — tap Get credits.";
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: _jsonUtf8);
      }
      if (request.url.path == '/chat/stream') {
        final body = [
          'data: ${jsonEncode({
                'type': 'reply',
                'text': message,
                'tools_used': <String>[],
                'usage_capped': true,
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'hey ayma');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // Renders as one Text.rich whose plain text is the *whole* sentence — if
    // this were split one character per line (each char its own Text/span),
    // no single widget would ever match the full string.
    final textFinder = find.text(message);
    expect(textFinder, findsOneWidget);

    // A short sentence at 1080-wide should take a handful of lines at most —
    // nowhere near the height a one-char-per-line render would produce.
    final size = tester.getSize(textFinder);
    expect(size.height, lessThan(150));

    expect(find.text('Get credits'), findsOneWidget);
  });

  testWidgets(
      'a draft_about kickoff chips the report above an empty composer — no send',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final hits = <String>[];
    final mockHttp = MockClient((request) async {
      hits.add('${request.method} ${request.url.path}');
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: _jsonUtf8);
      }
      if (request.url.path == '/chat/stream') {
        final body = [
          'data: ${jsonEncode({
                'type': 'reply',
                'text': "Reading it now.",
                'tools_used': <String>[],
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    ChatInbox.instance.push(ChatKickoff.draftAbout(
      targetUid: 'u_dana',
      label: 'Dana',
      shareKind: 'deep_dive',
      refId: 'dive1',
    ));
    await tester.pumpAndSettle();

    // The chip is up, the composer is empty, and nothing was sent.
    expect(find.text('Web research on Dana'), findsOneWidget);
    expect(hits, isNot(contains('POST /chat/stream')));
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller?.text ?? '', isEmpty);

    // The user types their own question and sends: the shared card is posted
    // as a turn alongside their text, and the turn goes out.
    await tester.enterText(
        find.byType(TextField).last, 'what stands out here?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(hits, contains('POST /chat/stream'));
    expect(find.text('what stands out here?'), findsOneWidget);
    // The card (still labelled the same) is now in the transcript.
    expect(find.text('Web research on Dana'), findsOneWidget);
  });
}
