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

/// Founder's report (bug 2): send a message, background the app while Ayma
/// is "thinking", and it comes back showing a network error — even though
/// nothing about the request itself was actually broken. `chat_screen.dart`
/// has no lifecycle-cancellation code (confirmed by reading it and
/// `api_client.dart` — no `WidgetsBindingObserver`, no `CancelToken`, no
/// explicit `.cancel(`), so this isn't the app deliberately tearing the
/// request down; it's the OS suspending/throttling the socket once
/// backgrounded (there's no foreground-service/background-execution
/// entitlement for a plain chat send, unlike a live voice call — see
/// `CallBackgroundService`'s doc comment for why *that* needs one), which
/// can surface as a dead-socket error on the client even though the server
/// already finished and persisted the reply.
///
/// The fix: `_ChatScreenState` now tracks (via `WidgetsBindingObserver`)
/// whether the app left the foreground while a send was in flight. If a
/// `/chat/stream` (+ `/chat` fallback) failure follows a backgrounding, the
/// screen polls `/chat/history` a few times — same idea as the existing
/// `_awaitBackgroundReply` used for a queued background skill — before
/// showing a hard error, and resolves the "Thinking…" turn with the reply
/// if it already landed server-side.
void main() {
  tearDown(() => ChatInbox.instance.take());

  http.Response historyPage(List<Map<String, String>> messages) =>
      http.Response(
        jsonEncode({'messages': messages, 'next_before': null}),
        200,
        headers: _jsonUtf8,
      );

  testWidgets(
      'backgrounding mid-send recovers the reply from history instead of '
      'showing a hard error', (tester) async {
    var historyCalls = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        historyCalls++;
        // The server already finished and persisted the reply by the second
        // poll — the client's own stream connection was the only casualty.
        if (historyCalls < 2) return historyPage(const []);
        return historyPage([
          {
            'role': 'ayma',
            'text': 'Got it — here you go.',
            'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ]);
      }
      if (request.url.path == '/chat/stream' || request.url.path == '/chat') {
        // Simulate the dead socket a backgrounded app's request comes back
        // to: a hard transport failure on both the stream and its fallback —
        // delayed a little so the request is still genuinely in flight when
        // the test backgrounds the app below (matching the founder's real
        // sequence: background *while* Ayma is still "thinking").
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('', 502);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'are you there?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pump(); // `_sending` is now true, request in flight

    // The app leaves the foreground while the request is still in flight —
    // exactly the founder's reported sequence.
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(s);
    }

    // Let the failed stream + fallback + the recovery polls all play out.
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Recovered quietly — no error snackbar, and the real reply landed.
    expect(find.text('Got it — here you go.'), findsOneWidget);
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
  });

  testWidgets(
      'a send failure with no backgrounding still shows the normal error '
      '(no regression)', (tester) async {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return historyPage(const []);
      }
      if (request.url.path == '/chat/stream' || request.url.path == '/chat') {
        return http.Response('', 502);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'are you there?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pumpAndSettle();

    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsOneWidget);
  });
}
