// Proves the Match report's "Ask Ayma" toolbar button (a `talk_about`
// kickoff, `shareKind: 'match'`, pushed by `MatchReportScreen._askAyma` —
// see `match_report_screen_test.dart`'s own kickoff-shape test) actually
// carries `match_report_id` through to the real `/chat` request body once
// `ChatScreen` consumes it, the same wire-level rigor
// `ask_ayma_overlay_wire_body_test.dart` uses for the Story/deep-dive
// context fields. `/chat/stream` is made to fail so the real fallback path
// in `ChatScreen._send` is the one exercised.
import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets(
      "a match report's Ask Ayma kickoff carries match_report_id on the "
      'real outgoing /chat request body, including a later follow-up turn '
      'in the same session', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final chatCalls = <Map<String, dynamic>>[];
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      if (request.url.path == '/chat/stream') {
        return http.Response('stream unavailable', 500);
      }
      if (request.url.path == '/chat') {
        chatCalls.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({'reply': "Here's my read.", 'usage_capped': false}),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );

    final router = GoRouter(
      initialLocation: '/',
      routes: [GoRoute(path: '/', builder: (_, __) => ChatScreen(apiClient: api))],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // Same shape `MatchReportScreen._askAyma` pushes — see
    // `match_report_screen_test.dart`'s "pushes a talk_about kickoff" test.
    ChatInbox.instance.push(ChatKickoff.talkAbout(
      targetUid: 'a',
      label: 'Sam Vale',
      shareKind: 'match',
      refId: 'a__me',
    ));
    await tester.pumpAndSettle();

    expect(chatCalls, hasLength(1));
    expect(chatCalls.single['match_report_id'], 'a__me');
    expect(chatCalls.single['message'], contains('match report'));

    // The founder's own scenario ("I don't live in Colorado" -> tool fix ->
    // Recalculate) plays out over a follow-up turn, not just the seeded
    // opener — it must keep carrying the id for the rest of the session.
    await tester.enterText(
        find.byType(TextField).last, "I don't live in Colorado");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(chatCalls, hasLength(2));
    expect(chatCalls.last['match_report_id'], 'a__me');
    expect(chatCalls.last['message'], "I don't live in Colorado");
  });
}
