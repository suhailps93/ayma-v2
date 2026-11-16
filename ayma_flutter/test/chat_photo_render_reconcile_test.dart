import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// NOTE 230 regression tests:
/// A slow photo turn causes a client-side timeout (ApiException with 408 or
/// 'Request timed out').
///
/// Bug:
/// 1. `_shouldReconcile` only checked `statusCode == null && message.startsWith('Network error')`.
///    The client-fabricated 408 timeout from `BudgetHttpClient` was not recognized
///    as reconcilable, so `_store.dropPending()` dropped the turn and toasted
///    "Couldn't reach Ayma. Check your connection."
/// 2. While remaining on the chat screen, reconciliation had no periodic foreground
///    polling loop, so once the initial 3 polls failed and fallback timed out,
///    the screen sat stale until the user switched tabs and reopened.
void main() {
  tearDown(() => ChatInbox.instance.take());

  http.Response historyPage(List<Map<String, dynamic>> messages) =>
      http.Response(
        jsonEncode({'messages': messages, 'next_before': null}),
        200,
        headers: _jsonUtf8,
      );

  String? sentClientMsgId(http.Request request) {
    try {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return body['client_msg_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  testWidgets(
      'NOTE 230: a client-side 408 timeout enters reconciliation instead of dropping pending turn and flashing error toast',
      (tester) async {
    final msgIds = <String>[];
    var historyCalls = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        historyCalls++;
        if (historyCalls < 3 || msgIds.isEmpty) return historyPage(const []);
        return historyPage([
          {
            'role': 'ayma',
            'text': 'Looking great! That is a lovely portrait.',
            'client_msg_id': msgIds.first,
            'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ]);
      }
      if (request.url.path == '/chat/stream') {
        // Stream connection timed out
        throw http.ClientException('Connection closed while receiving data');
      }
      if (request.url.path == '/chat') {
        msgIds.add(sentClientMsgId(request) ?? '');
        // BudgetHttpClient timeout: 408 Request timed out
        return http.Response(
          jsonEncode({'error': 'Request timed out — please try again.'}),
          408,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });

    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Here is my photo');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Must NOT drop pending or show error toast:
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
    expect(find.text('Retry'), findsNothing);

    // It must be in reconnecting / waiting state:
    expect(
      find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data == 'Reconnecting…' || w.data == 'Waiting for a connection…')),
      findsOneWidget,
    );

    // When history returns the reply, it adopts it:
    await tester.pumpAndSettle(const Duration(seconds: 4));
    expect(
        find.text('Looking great! That is a lovely portrait.'), findsOneWidget);
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
  });

  testWidgets(
      'NOTE 230: foreground periodic reconciliation resolves pending turn when server finishes after initial polls',
      (tester) async {
    final msgIds = <String>[];
    var historyCalls = 0;
    var resendCalls = 0;

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        historyCalls++;
        // Turn doesn't land during the first 3 polls (calls 1-4 including initial load).
        // It lands on call 5 (periodic foreground poll after resend timeout).
        if (historyCalls < 5 || msgIds.isEmpty) return historyPage(const []);
        return historyPage([
          {
            'role': 'ayma',
            'text': 'Photo received and verified!',
            'client_msg_id': msgIds.first,
            'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ]);
      }
      if (request.url.path == '/chat/stream') {
        throw http.ClientException('Connection closed while receiving data');
      }
      if (request.url.path == '/chat') {
        msgIds.add(sentClientMsgId(request) ?? '');
        resendCalls++;
        // The resend also times out while the server is still busy
        return http.Response(
          jsonEncode({'error': 'Request timed out — please try again.'}),
          408,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });

    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Check my picture');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pump();

    // Initial polls (0s, 2s, 4s) + resend attempt
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    // The user stays in foreground on ChatScreen (no app resume, no tab switch).
    // The periodic foreground poll should fire and pick up the server turn:
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('Photo received and verified!'), findsOneWidget);
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
    expect(resendCalls, greaterThanOrEqualTo(1));
  });
}
