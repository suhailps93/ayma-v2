// Proves the Ask-Ayma modal's context-seeding fields reach the real
// `/chat` request body at the wire level — a `MockClient` under a genuine
// `ApiClient` (its real `jsonEncode`/HTTP-call code, not a fake subclass
// standing in for it), so this can't silently diverge from what
// `api_client.dart` actually sends. `/chat/stream` is made to fail so the
// real fallback path in `ChatScreen._send` is the one exercised, matching
// `ask_ayma_overlay_origin_test.dart`'s existing (subclass-level) coverage —
// this file adds the wire-level check that coverage doesn't.
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
      'deep-dive context fields land in the real /chat request body',
      (tester) async {
    http.Request? capturedChatRequest;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/stream') {
        // Force the real fallback in `ChatScreen._send` — same trick every
        // other Ask-Ayma test in this app uses.
        return http.Response('stream unavailable', 500);
      }
      if (request.url.path == '/chat') {
        capturedChatRequest = request;
        return http.Response(
          jsonEncode({'reply': 'Got it, noted.', 'usage_capped': false}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('not found', 404);
    });
    final api = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAskAymaOverlay(
              context,
              api: api,
              ctx: const AskAymaContext(
                origin: AskAymaOrigin.deepDiveFact,
                deepDiveReportId: 'report-42',
                deepDiveTarget: 'fact:employer',
                quoteText: 'Works at Acme Corp',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, "that's outdated");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(capturedChatRequest, isNotNull);
    final body =
        jsonDecode(capturedChatRequest!.body) as Map<String, dynamic>;
    expect(body['message'], "that's outdated");
    expect(body['deep_dive_report_id'], 'report-42');
    expect(body['deep_dive_target'], 'fact:employer');
    expect(body['appearance_finding_id'], '');
    expect(body['story_page_id'], '');
    expect(body['story_timeline_entry_id'], '');
  });

  testWidgets(
      'story timeline-entry context lands in the real /chat request body, '
      'and the passage field stays empty for a timeline entry',
      (tester) async {
    http.Request? capturedChatRequest;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/stream') {
        return http.Response('stream unavailable', 500);
      }
      if (request.url.path == '/chat') {
        capturedChatRequest = request;
        return http.Response(
          jsonEncode({'reply': 'Updated.', 'usage_capped': false}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('not found', 404);
    });
    final api = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAskAymaOverlay(
              context,
              api: api,
              ctx: const AskAymaContext(
                pageId: 'career',
                timelineEntryId: 'entry-7',
                timelineEntryLabel: 'Acme Corp — Engineer',
                selectedText: 'unused when a timeline entry is set',
                quoteText: 'Acme Corp — Engineer',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Delete');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(capturedChatRequest, isNotNull);
    final body =
        jsonDecode(capturedChatRequest!.body) as Map<String, dynamic>;
    expect(body['message'], 'Delete');
    expect(body['story_page_id'], 'career');
    expect(body['story_timeline_entry_id'], 'entry-7');
    expect(body['story_passage'], '');
  });
}
