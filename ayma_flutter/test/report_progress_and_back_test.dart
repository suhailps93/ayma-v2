// Tester feedback round (iPhone): in-progress indicators on report screens,
// a back affordance everywhere, a keyboard-dismiss arrow on the Ayma chat tab,
// and tappable links / photo fallbacks in reports.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/screens/plans_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/pending_chat_queue.dart';
import 'package:ayma_flutter/widgets/ayma_back_button.dart';
import 'package:ayma_flutter/widgets/living_report_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _photoReport() => {
      'title': 'Web search: Jane',
      'sections': [
        {
          'heading': 'Notes',
          'blocks': [
            {
              'block_id': 'fact:1',
              'type': 'fact',
              'editable': false,
              'text': 'See https://example.com/jane for more.',
            },
          ],
        },
        {
          'heading': 'Photos to confirm',
          'blocks': [
            {
              'block_id': 'candidate:c1',
              'type': 'photo',
              'editable': false,
              'url': 'https://p19-common-sign.tiktokcdn-us.com/x.jpeg',
              'caption': 'p19-common-sign.tiktokcdn-us.com',
              'status': 'pending',
            },
          ],
        },
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': false,
        'created_at': null,
        'updated_at': null,
      },
    };

void main() {
  testWidgets('report photo thumbnail + caption and URLs in text are tappable',
      (tester) async {
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async =>
          http.Response(jsonEncode(_photoReport()), 200, headers: _json)),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
            reportType: 'deep_dive', reportId: 'r1', apiClient: api),
      ),
    ));
    await tester.pumpAndSettle();

    final thumb =
        tester.widget<InkWell>(find.byKey(const ValueKey('photoRowThumb')));
    final caption =
        tester.widget<InkWell>(find.byKey(const ValueKey('photoRowCaption')));
    expect(thumb.onTap, isNotNull);
    expect(caption.onTap, isNotNull);
    expect(find.text('p19-common-sign.tiktokcdn-us.com'), findsOneWidget);
    // The bare URL inside a fact is rendered as its own tappable span.
    final rich = find.byWidgetPredicate((w) =>
        w is RichText &&
        w.text.toPlainText().contains('https://example.com/jane'));
    expect(rich, findsOneWidget);
  });

  testWidgets('AymaBackButton pops when it can and goes to the shell otherwise',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('SHELL')),
        ),
        GoRoute(
          path: '/a',
          builder: (_, __) => Scaffold(
            appBar: AppBar(leading: const AymaBackButton()),
            body: const Text('A'),
          ),
        ),
        GoRoute(
          path: '/b',
          builder: (_, __) => Scaffold(
            appBar: AppBar(leading: const AymaBackButton()),
            body: const Text('B'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // Nothing below /a: back lands on the shell.
    await tester.tap(find.byType(AymaBackButton));
    await tester.pumpAndSettle();
    expect(find.text('SHELL'), findsOneWidget);

    // Pushed: back pops to the previous page.
    unawaited(router.push('/b'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    await tester.tap(find.byType(AymaBackButton));
    await tester.pumpAndSettle();
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('a screen opened without history (plans) still has a back arrow',
      (tester) async {
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient:
          MockClient((req) async => http.Response('{"plans":[]}', 200)),
    );
    await tester.pumpWidget(MaterialApp(home: PlansScreen(api: api)));
    await tester.pump();
    expect(find.byType(AymaBackButton), findsOneWidget);
  });

  testWidgets('web research re-run shows a spinner + banner until it lands',
      (tester) async {
    var metaCalls = 0;
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/deep-dive-report/rid1') {
          metaCalls++;
          return http.Response(
              jsonEncode({
                'name': 'Jane',
                'is_self': true,
                'created_at': metaCalls <= 1 ? 't1' : 't2',
                'digest': {'summary': 's', 'facts': <dynamic>[]},
              }),
              200,
              headers: _json);
        }
        if (req.url.path == '/report/deep_dive/rid1') {
          return http.Response(jsonEncode(_photoReport()), 200, headers: _json);
        }
        if (req.url.path == '/deep-dive') {
          return http.Response(jsonEncode({'queued': true}), 200,
              headers: _json);
        }
        return http.Response('{}', 200);
      }),
    );
    await tester.pumpWidget(MaterialApp(
        home: DeepDiveReportScreen(reportId: 'rid1', apiClient: api)));
    await tester.pumpAndSettle();
    expect(find.text('Searching the web again…'), findsNothing);

    await tester.tap(find.byTooltip('Re-run'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Searching the web again…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(
        tester.widget<IconButton>(find.byType(IconButton).last).onPressed,
        isNull);

    // The poll sees a new createdAt and clears the in-progress state.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Searching the web again…'), findsNothing);
    expect(find.byTooltip('Re-run'), findsOneWidget);
  });

  testWidgets('match recalculate shows a spinner + banner while in flight',
      (tester) async {
    final gate = Completer<http.Response>();
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/check-compatibility') return gate.future;
        if (req.url.path == '/report/match/a__me') {
          return http.Response(
              jsonEncode({
                'title': 'Match',
                'sections': <dynamic>[],
                'meta': {
                  'owner_uid': 'me',
                  'viewer_can_edit': false,
                  'created_at': null,
                  'updated_at': null,
                },
              }),
              200,
              headers: _json);
        }
        if (req.url.path.startsWith('/match/')) {
          return http.Response(
              jsonEncode({
                'match_id': 'a__me',
                'score': 0.5,
                'shared': const [],
                'tensions': const [],
                'missing': const [],
                'explanation': 'x',
                'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
                'me': {'photo': ''},
              }),
              200);
        }
        return http.Response('no', 404);
      }),
    );
    await tester.pumpWidget(MaterialApp(
        home: MatchReportScreen(matchId: 'a__me', apiClient: api)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.text('Recalculating this match…'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);

    gate.complete(http.Response(jsonEncode({'ok': true}), 200));
    await tester.pumpAndSettle();
    expect(find.text('Recalculating this match…'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('Ayma chat tab shows a back arrow that hides the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => ChatInbox.instance.take());

    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient:
          MockClient((req) async => http.Response('{}', 200, headers: _json)),
    );
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        pendingQueue: PendingChatQueue(api: api, currentUid: () => null),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chatDismissKeyboardButton')), findsNothing);

    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chatDismissKeyboardButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chatDismissKeyboardButton')));
    await tester.pump();
  });
}
