import 'dart:convert';

import 'package:ayma_flutter/screens/connect_agent_screen.dart';
import 'package:ayma_flutter/services/mcp_connect_service.dart';
import 'package:ayma_flutter/theme.dart';
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

    // Jobs defect 13: the MCP URL text reads in the derived accentText token
    // (passes 4.5 on bgCard), not the raw accent (4.02/3.29, sub-floor).
    final urlFinder = find.byType(SelectableText);
    final ac = tester.element(urlFinder.first).ac;
    expect(tester.widget<SelectableText>(urlFinder.first).style!.color,
        ac.accentText);

    // Jobs defect 16: the URL row indents 34 (22 circle + 12 gap) under the
    // step text, and its top inset is 8 (defect 15), not the old 32/6.
    expect(
      find.byWidgetPredicate((w) =>
          w is Padding &&
          w.padding == const EdgeInsets.only(left: 34, top: 8, bottom: 4)),
      findsOneWidget,
    );

    // Jobs defect 17: the Learn-more TextButton strips the M3 inset so its
    // label joins the card's 16 content edge.
    final learnMore =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Learn more'));
    expect(learnMore.style!.padding!.resolve({}), EdgeInsets.zero);
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

  testWidgets(
      'approved agent appears in place once it finishes connecting, and '
      'disconnect also refreshes in place', (tester) async {
    // A tall surface, same as pump() above, so the whole screen builds.
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The server truth this screen reads: approving a code does not
    // create the connection the list shows — the agent creates it when
    // it next polls the server to collect its token. `redeemed` stands
    // in for that poll.
    var redeemed = false;
    var revoked = false;
    final svc = McpConnectService(
      auth: auth,
      client: MockClient((req) async {
        http.Response json(Object body) => http.Response(
              jsonEncode(body),
              200,
              headers: const {'content-type': 'application/json'},
            );
        final path = req.url.path;
        if (path.endsWith('/mcp/connect/pending')) {
          return json({
            'client_id': 'claude-code',
            'scope': ['profile:read', 'dm:send'],
          });
        }
        if (path.endsWith('/mcp/connect/approve')) {
          return json({'ok': true, 'approved': true});
        }
        if (path.endsWith('/mcp/connect/tokens/revoke')) {
          revoked = true;
          return json({'ok': true});
        }
        if (path.endsWith('/mcp/connect/tokens')) {
          return json({
            'connections': [
              if (redeemed && !revoked)
                {
                  'token_id': 'tok-1',
                  'client_id': 'claude-code',
                  'scope': ['profile:read', 'dm:send'],
                  'created_at': '2026-11-09T07:33:00Z',
                  'last_used_at': null,
                },
            ],
          });
        }
        return http.Response('{}', 404);
      }),
    );
    // The connected-agents section sits below the fold of this tall
    // screen, and the ListView only builds what is near the viewport —
    // drag the list until a target is built, then interact with it.
    Future<void> reveal(Finder target) async {
      for (var i = 0; i < 25 && target.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      // Built is not the same as on screen: the list also builds a
      // cache band below the fold, and a tap there misses. Bring the
      // target fully into the viewport before interacting with it.
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(home: ConnectAgentScreen(service: svc)),
    );
    await tester.pumpAndSettle();
    // The connected-agents section sits below the fold of this tall
    // screen; scroll it into the built range before asserting on it.
    await reveal(find.text('No agents are connected.'));
    expect(find.text('No agents are connected.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ABCD-2345');
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await reveal(find.text('Approve'));
    expect(find.text('Approve'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    // Approval succeeded, but the agent has not collected its token yet,
    // so the list is still empty — this is the moment that used to stick
    // until the user left the screen and came back.
    await reveal(find.text('No agents are connected.'));
    expect(find.text('No agents are connected.'), findsOneWidget);
    expect(find.text('claude-code'), findsNothing);

    // The agent finishes connecting; the screen must notice on its own,
    // without being re-entered.
    redeemed = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await reveal(find.text('claude-code'));
    expect(find.text('claude-code'), findsOneWidget);
    expect(find.text('No agents are connected.'), findsNothing);

    // Disconnect refreshes the list in place too.
    await reveal(find.text('Disconnect'));
    // Jobs defect 18: the Disconnect TextButton strips the M3 inset so its
    // label joins the list's 20 edge.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Disconnect'))
          .style!
          .padding!
          .resolve({}),
      EdgeInsets.zero,
    );
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await reveal(find.text('No agents are connected.'));
    expect(find.text('claude-code'), findsNothing);
    expect(find.text('No agents are connected.'), findsOneWidget);
  });
}
