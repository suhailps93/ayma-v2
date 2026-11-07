import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// Founder bug (2026-11-03, voice): on the Web research report's "Ask Ayma"
/// sheet, tapping DELETE on an item WHILE A VOICE CALL IS ON toasted a false
/// "Couldn't reach Ayma. Check your connection." — but the delete actually
/// SUCCEEDED (the item was gone). Text mode was clean. A live call contends
/// for the network, so the `POST /report/{type}/{id}/correct` request's socket
/// dies while the server still commits the delete; the report-correct branch
/// then flashed a connection error for a turn that succeeded.
///
/// Fix (client): a CONNECTION-class failure on that branch (an `ApiException`
/// with no HTTP status — a dead socket / timeout, NOT a real 4xx/5xx) now
/// reconciles — it reloads the report (via `onExchange`) so the UI reflects
/// what committed and shows NO error — mirroring the `/chat` branch's
/// `_shouldReconcile`. A genuine server rejection still surfaces honestly.
const _reportCtx = AskAymaContext(
  origin: AskAymaOrigin.report,
  reportType: 'deep_dive',
  reportId: 'r1',
  blockIds: ['link:https://example.com/me'],
  quoteTitle: 'Personal Website',
  quoteText: 'https://example.com/me',
);

void main() {
  Future<void> pumpChat(
    WidgetTester tester, {
    required http.Client mockHttp,
    required VoidCallback onExchange,
  }) async {
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        askAymaContext: _reportCtx,
        onExchange: onExchange,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapDelete(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).last, 'Delete');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
      'a dropped socket on the delete (voice contention) reconciles: reloads '
      'the report, NO false connection error', (tester) async {
    var reloads = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path.endsWith('/correct')) {
        // The live call's network pressure killed the socket mid-request — a
        // transport death, not a server reply. The server committed the delete
        // anyway (only the response was lost).
        throw http.ClientException('Connection closed while receiving data');
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });

    await pumpChat(tester, mockHttp: mockHttp, onExchange: () => reloads++);
    await tapDelete(tester);

    // The success path is unreachable (socket died), but the delete committed
    // server-side — so NO false failure toast…
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
    // …and the report is reloaded so the UI reflects the committed delete.
    expect(reloads, greaterThan(0));
  });

  testWidgets(
      'a genuine server rejection (500) still surfaces an honest error',
      (tester) async {
    var reloads = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path.endsWith('/correct')) {
        return http.Response('{"detail":"boom"}', 500, headers: _jsonUtf8);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });

    await pumpChat(tester, mockHttp: mockHttp, onExchange: () => reloads++);
    await tapDelete(tester);

    // A real failure (not a dropped socket) is NOT silently reconciled — the
    // user is told honestly and offered a retry.
    expect(find.text("Ayma hit a problem with that message — try again."),
        findsOneWidget);
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
    expect(reloads, 0);
  });

  testWidgets('a normal (text-mode) delete still resolves cleanly',
      (tester) async {
    var reloads = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path.endsWith('/correct')) {
        return http.Response(
          '{"ok":true,"results":[{"block_id":"link:https://example.com/me",'
          '"ok":true,"reply":"Done — it won\'t come back."}]}',
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });

    await pumpChat(tester, mockHttp: mockHttp, onExchange: () => reloads++);
    await tapDelete(tester);

    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);
    expect(find.text("Done — it won't come back."), findsOneWidget);
    expect(reloads, greaterThan(0));
  });
}
