import 'package:ayma_flutter/screens/connect_agent_screen.dart';
import 'package:ayma_flutter/services/mcp_connect_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// "Connect an agent" must tell the user HOW to connect, not just show a code
/// box. These assert the step-by-step instructions, the MCP URL, and the
/// "Learn more" affordance render — and that an honest note appears when the
/// `mcp_server` flag is off (a 503 from the server).
void main() {
  final auth = MockFirebaseAuth(
    signedIn: true,
    mockUser: MockUser(uid: 'me', email: 'me@example.com'),
  );

  Future<void> pump(WidgetTester tester, {required int status}) async {
    // A tall surface so the whole screen builds at once (no lazy-list
    // disposal of the top note while we interact with the button below).
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final svc = McpConnectService(
      auth: auth,
      client: MockClient((req) async {
        // Listing connections stays available even when the flag is off; the
        // approval/pending endpoints are what return 503.
        if (req.url.path.endsWith('/mcp/connect/tokens')) {
          return http.Response('{"connections": []}', 200,
              headers: const {'content-type': 'application/json'});
        }
        return http.Response('{"error": "mcp_disabled"}', status,
            headers: const {'content-type': 'application/json'});
      }),
    );
    await tester.pumpWidget(
      MaterialApp(home: ConnectAgentScreen(service: svc)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the step-by-step instructions, the MCP URL and Learn more',
      (tester) async {
    await pump(tester, status: 200);

    expect(find.text('How to connect'), findsOneWidget);
    expect(
      find.textContaining('add Ayma as an MCP server'),
      findsOneWidget,
    );
    expect(find.textContaining('tap Review'), findsOneWidget);
    expect(find.textContaining('act for you'), findsWidgets);
    // The real endpoint, derived from the API base — not hardcoded.
    expect(find.textContaining('/mcp'), findsWidgets);
    expect(find.text('Learn more'), findsOneWidget);
  });

  testWidgets('shows the "what your agent can do" capabilities section',
      (tester) async {
    await pump(tester, status: 200);

    expect(find.text('What your agent can do'), findsOneWidget);
    // The real MCP capabilities, in plain language.
    expect(find.text('Update your profile & story'), findsOneWidget);
    expect(find.text('See and understand your matches'), findsOneWidget);
    expect(find.text('Read your conversations'), findsOneWidget);
    expect(find.text('Help you practice & prep'), findsOneWidget);
    // The guardrails line: same safety checks, your data only, revoke anytime.
    expect(find.textContaining('18+, moderation and'), findsOneWidget);
    expect(find.textContaining('disconnect it anytime'), findsOneWidget);
  });

  testWidgets('Learn more opens the help sheet', (tester) async {
    await pump(tester, status: 200);

    await tester.tap(find.text('Learn more'));
    await tester.pumpAndSettle();

    expect(find.text('Connecting an agent'), findsOneWidget);
    // The sheet's own safety copy ("Ayma is 18+"), distinct from the
    // capabilities card's guardrails line which also mentions 18+.
    expect(find.textContaining('Ayma is 18+'), findsOneWidget);
  });

  testWidgets('shows an honest note when the feature flag is off', (tester) async {
    await pump(tester, status: 503);

    // No disabled note until the server tells us (Review triggers the call).
    expect(find.textContaining("aren't switched on yet"), findsNothing);

    await tester.enterText(find.byType(TextField), 'ABCD-2345');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.textContaining("aren't switched on yet"), findsOneWidget);
  });
}
