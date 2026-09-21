import 'dart:convert';

import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

ApiClient _api(
  Map<String, dynamic>? report, {
  int status = 200,
  Map<String, dynamic>? compat,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/check-compatibility') {
        return http.Response(jsonEncode(compat ?? {'ok': true}), 200);
      }
      if (req.url.path.startsWith('/match/')) {
        return http.Response(
            report == null ? 'no' : jsonEncode(report), status);
      }
      return http.Response('no', 404);
    }),
  );
}

/// A GoRouter host so `context.push('/profile/usage')` from the out-of-credits
/// snackbar has somewhere to land.
Widget _routed(Widget screen) => MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/match/a__me',
        routes: [
          GoRoute(path: '/match/a__me', builder: (_, __) => screen),
          GoRoute(
            path: '/profile/usage',
            builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
          ),
        ],
      ),
    );

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
  });

  testWidgets('renders the score, both breakdown lists and the note',
      (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': ['both want kids soon', 'love long runs'],
      'tensions': ['she wants city life, he wants a small town'],
      'missing': ['how conflict gets handled after a fight'],
      'explanation': 'You two line up on the big things.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('52%'), findsOneWidget);
    expect(find.text('You two line up on the big things.'), findsOneWidget);
    expect(find.text('both want kids soon'), findsOneWidget);
    expect(find.text('she wants city life, he wants a small town'),
        findsOneWidget);
    expect(find.text('Sam'), findsOneWidget); // avatar label = first name
    // The "what's missing" section renders its items.
    expect(find.text("WHAT'D SHARPEN THIS SCORE"), findsOneWidget);
    expect(
        find.text('how conflict gets handled after a fight'), findsOneWidget);
  });

  testWidgets('the "what\'d sharpen this score" section is hidden when empty',
      (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.7,
      'shared': const [],
      'tensions': const [],
      'missing': const [],
      'explanation': 'Solid.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text("WHAT'D SHARPEN THIS SCORE"), findsNothing);
  });

  testWidgets('Copy summary is gone from the report', (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': ['both want kids soon'],
      'tensions': const [],
      'explanation': 'Line up on the big things.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Copy summary'), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsNothing);
  });

  testWidgets('Recalculate and Ask Ayma sit in the AppBar', (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': ['both want kids soon'],
      'tensions': const [],
      'explanation': 'Line up on the big things.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    final inAppBar = find.byType(AppBar);
    expect(find.descendant(of: inAppBar, matching: find.byIcon(Icons.refresh)),
        findsOneWidget);
    expect(find.descendant(of: inAppBar, matching: find.text('Ask Ayma')),
        findsOneWidget);
    expect(find.descendant(of: inAppBar, matching: find.text('Copy summary')),
        findsNothing);
  });

  testWidgets(
      'tapping Recalculate in the AppBar still triggers the same '
      'recalculation flow (force re-run, then reload the report)',
      (tester) async {
    // Non-queued (immediate) recalc path: no MatchActivity polling involved,
    // so this can't leak background state into later tests. Returns a
    // different score on the second /match/ fetch to prove the reload ran.
    var matchCalls = 0;
    final compatCalls = <bool>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/check-compatibility') {
          compatCalls.add(jsonDecode(req.body)['force'] == true);
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (req.url.path.startsWith('/match/')) {
          matchCalls++;
          return http.Response(
              jsonEncode({
                'match_id': 'a__me',
                'score': matchCalls == 1 ? 0.52 : 0.71,
                'shared': const [],
                'tensions': const [],
                'missing': const [],
                'explanation': 'Solid.',
                'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
                'me': {'photo': ''},
              }),
              200);
        }
        return http.Response('no', 404);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();
    expect(find.text('52%'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(compatCalls, [true]); // called with force: true
    expect(find.text('71%'), findsOneWidget); // report reloaded
  });

  testWidgets(
      'tapping Ask Ayma in the AppBar pushes a talk_about kickoff and '
      'opens the chat shell', (tester) async {
    addTearDown(() => ChatInbox.instance.take());
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': const [],
      'tensions': const [],
      'missing': const [],
      'explanation': 'Solid.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    final router = GoRouter(
      initialLocation: '/match/a__me',
      routes: [
        GoRoute(
            path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
        GoRoute(
          path: '/match/a__me',
          builder: (_, __) =>
              MatchReportScreen(matchId: 'a__me', apiClient: api),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask Ayma'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'talk_about');
    expect(k.shareKind, 'match');
    expect(k.refId, 'a__me');
    expect(k.targetUid, 'a');
    expect(k.label, 'Sam Vale');
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('confidence chip + note render from the report', (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.61,
      'score_confidence': 0.82,
      'confidence_note': 'High confidence - both profiles are detailed.',
      'shared': const [],
      'tensions': const [],
      'missing': const [],
      'explanation': 'Solid.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Confidence: High'), findsOneWidget);
    expect(find.text('High confidence - both profiles are detailed.'),
        findsOneWidget);
  });

  Map<String, dynamic> dealbreakerReport(List<Map<String, String>> gates) => {
        'match_id': 'a__me',
        'score': 0.2,
        'score_confidence': 0.5,
        'confidence_note': 'Medium confidence.',
        'gate_failures': gates,
        'shared': const [],
        'tensions': const [],
        'missing': const [],
        'explanation': '',
        'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
        'me': {'photo': ''},
      };

  testWidgets('Dealbreakers section shows when gate_failures present',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(
        matchId: 'a__me',
        apiClient: _api(dealbreakerReport([
          {
            'label': 'Kids & timeline',
            'reason': 'One is firmly childfree; the other wants children.',
          }
        ])),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('DEALBREAKERS'), findsOneWidget);
    expect(
        find.text('One is firmly childfree; the other wants children.'),
        findsOneWidget);
  });

  testWidgets('Dealbreakers section is absent when gate_failures empty',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(
          matchId: 'a__me', apiClient: _api(dealbreakerReport(const []))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('DEALBREAKERS'), findsNothing);
  });

  testWidgets('a dimension shows its measured / estimated source tag',
      (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.6,
      'score_confidence': 0.7,
      'confidence_note': 'High confidence.',
      'dimensions': [
        {
          'key': 'values',
          'label': 'Values & worldview',
          'weight': 0.22,
          'score': 72.0,
          'rationale': 'measured from answers',
          'evidence': const [],
          'confidence': 'high',
          'source': 'structured',
          'covered_nodes': const ['procreation_intent'],
        },
        {
          'key': 'interests',
          'label': 'Shared interests',
          'weight': 0.04,
          'score': 50.0,
          'rationale': 'estimated',
          'evidence': const [],
          'confidence': 'low',
          'source': 'llm',
        },
      ],
      'shared': const [],
      'tensions': const [],
      'missing': const [],
      'explanation': '',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('measured'), findsOneWidget);
    expect(find.text('estimated'), findsOneWidget);
  });

  testWidgets('a capped recalc shows an out-of-credits snack with a Reload '
      'action that opens the reload screen', (tester) async {
    final api = _api(
      {
        'match_id': 'a__me',
        'score': 0.52,
        'shared': const [],
        'tensions': const [],
        'missing': const [],
        'explanation': 'Solid.',
        'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
        'me': {'photo': ''},
      },
      compat: {'ok': false, 'usage_capped': true},
    );

    await tester.pumpWidget(_routed(
      MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, 'Reload'));
    await tester.pumpAndSettle();
    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets('a never-scored pair shows the empty state', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(
          matchId: 'a__me', apiClient: _api(null, status: 404)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("hasn't been scored"), findsOneWidget);
  });
}
