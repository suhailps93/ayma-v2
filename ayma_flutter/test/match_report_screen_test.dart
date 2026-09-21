import 'dart:convert';

import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('Copy summary copies a text summary to the clipboard',
      (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': ['both want kids soon'],
      'tensions': const [],
      'explanation': 'Line up on the big things.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy summary'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('Match with Sam Vale: 52%'));
    expect(copied, contains('both want kids soon'));
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

    // One banded, out-of-100 score bar per dimension (green/amber/red at a
    // glance), unlike Face/Body's flat unjudgmental bars.
    final bars = tester.widgetList<ScoreBar>(find.byType(ScoreBar)).toList();
    expect(bars, hasLength(2));
    for (final bar in bars) {
      expect(bar.max, 100);
      expect(bar.height, 6);
      expect(bar.colorFor, isNotNull);
    }
    expect(bars[0].value, 72.0);
    expect(bars[1].value, 50.0);
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

    await tester.tap(find.text('Recalculate'));
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
