// Tests for MatchReportScreen after it became a thin wrapper around the
// shared LivingReportView (§ generic reports, report_type "match" — see
// report_adapters.match_blocks / report_hub.py). Two things are exercised:
// - the bespoke screen chrome that stays outside the generic renderer (the
//   two-person photo/score header, the Confidence badge, Recalculate/Ask
//   Ayma/Copy summary), sourced from the existing `GET /match/{id}` fetch;
// - the report BODY, now fetched separately via `GET /report/match/{id}`
//   and rendered by LivingReportView — including the real-request-body
//   proof that a tap on match content never posts to
//   `/report/match/{id}/correct` (there is no correction path for this
//   report type — see report_hub.py's module docstring) and instead always
//   goes through plain, read-only `/chat`.
import 'dart:convert';

import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// A minimal but real Living Report body shaped like
/// `report_adapters.match_blocks`'s real output — `viewer_can_edit: false`
/// always, per the founder direction that match reports have no correction
/// path at all.
Map<String, dynamic> _livingReport({
  bool viewerCanEdit = false,
  List<Map<String, dynamic>>? extraSections,
}) => {
      'title': 'Match with Sam Vale',
      'sections': [
        {
          'heading': 'Match',
          'blocks': [
            {
              'block_id': 'score',
              'type': 'stat',
              'editable': false,
              'label': 'Match score',
              'value': '52%',
              'basis': 'High confidence',
            },
            {
              'block_id': 'explanation:sent:0',
              'type': 'text',
              'editable': false,
              'text': 'You two line up on the big things.',
            },
          ],
        },
        {
          'heading': 'Values & worldview',
          'blocks': [
            {
              'block_id': 'dim:values',
              'type': 'stat',
              'editable': false,
              'label': 'Values & worldview',
              'value': 80.0,
              'basis': '22% weight · measured',
            },
            {
              'block_id': 'dim:values:rationale',
              'type': 'fact',
              'editable': false,
              'text': 'Both prioritize family closely.',
              'tag': 'rationale',
              'confidence': 'high',
            },
          ],
        },
        ...?extraSections,
      ],
      'meta': {
        'owner_uid': 'me',
        'viewer_can_edit': viewerCanEdit,
        'created_at': null,
        'updated_at': null,
      },
    };

ApiClient _api({
  Map<String, dynamic>? matchMeta,
  int matchStatus = 200,
  Map<String, dynamic>? compat,
  Map<String, dynamic>? livingReport,
  int livingReportStatus = 200,
  List<Map<String, dynamic>>? correctCalls,
  List<Map<String, dynamic>>? chatCalls,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/check-compatibility') {
        return http.Response(jsonEncode(compat ?? {'ok': true}), 200);
      }
      if (req.method == 'GET' && req.url.path == '/match/a__me') {
        return http.Response(
            matchMeta == null ? 'no' : jsonEncode(matchMeta), matchStatus);
      }
      if (req.method == 'GET' && req.url.path == '/report/match/a__me') {
        return http.Response(
          livingReport == null ? 'no' : jsonEncode(livingReport),
          livingReportStatus,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (req.method == 'POST' &&
          req.url.path == '/report/match/a__me/correct') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        correctCalls?.add(body);
        return http.Response(
          jsonEncode({'ok': false, 'results': []}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (req.url.path == '/chat/stream') {
        return http.Response('stream unavailable', 500);
      }
      if (req.url.path == '/chat') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        chatCalls?.add(body);
        return http.Response(
          jsonEncode({'reply': 'Sure, ask away.', 'usage_capped': false}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 200);
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

Future<void> _sendComposer(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
  await tester.pumpAndSettle();
}

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

  Map<String, dynamic> matchMeta({
    double score = 0.52,
    double? scoreConfidence,
    String confidenceNote = '',
  }) =>
      {
        'match_id': 'a__me',
        'score': score,
        if (scoreConfidence != null) 'score_confidence': scoreConfidence,
        'confidence_note': confidenceNote,
        'shared': const [],
        'tensions': const [],
        'missing': const [],
        'explanation': 'You two line up on the big things.',
        'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
        'me': {'photo': ''},
      };

  testWidgets('renders the two-person header chrome (score %, avatar label)',
      (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // Shows at least once as the big chrome number between the avatars —
    // the real adapter's own "score" stat block also renders "52%" in the
    // body below it (see the next test), so this doesn't assert exactly
    // one.
    expect(find.text('52%'), findsWidgets);
    expect(find.text('Sam'), findsOneWidget); // avatar label = first name
  });

  testWidgets('confidence chip + note render as chrome from /match metadata',
      (tester) async {
    final api = _api(
      matchMeta: matchMeta(
        score: 0.61,
        scoreConfidence: 0.82,
        confidenceNote: 'High confidence - both profiles are detailed.',
      ),
      livingReport: _livingReport(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Confidence: High'), findsOneWidget);
    expect(find.text('High confidence - both profiles are detailed.'),
        findsOneWidget);
  });

  testWidgets(
      'the report body renders via the shared LivingReportView from '
      'GET /report/match/{id}', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // Chrome (header) and generic block content both visible together —
    // the header's big number and the adapter's own "score" stat block
    // both land on "52%" for a real report, so this is >=1, not exactly 1.
    expect(find.text('52%'), findsWidgets);
    expect(find.text('You two line up on the big things.'), findsOneWidget);
    expect(find.text('VALUES & WORLDVIEW'), findsOneWidget);
    expect(find.textContaining('Both prioritize family closely.'),
        findsOneWidget);
  });

  testWidgets(
      'dimension stat blocks render real banded ScoreBars end to end (§ '
      'founder: the match report lost its graphics after the Living Report '
      'migration — this is the fix), on top of the bespoke score-header '
      'chrome', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(extraSections: [
        {
          'heading': 'Shared interests',
          'blocks': [
            {
              'block_id': 'dim:interests',
              'type': 'stat',
              'editable': false,
              'label': 'Shared interests',
              'value': 30.0,
              'basis': '4% weight · estimated',
            },
          ],
        },
      ]),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // The header's own big "52%" chrome number stays plain text (bespoke,
    // not a block) — but the body's own top-line "Match score" stat block
    // (from `_livingReport()`'s "Match" section) is itself a numeric stat
    // now getting the exact same generic bar treatment as the dimensions
    // below it: score (52%) + dim:values (80) + dim:interests (30) = 3.
    final bars = tester.widgetList<ScoreBar>(find.byType(ScoreBar)).toList();
    expect(bars, hasLength(3));
    for (final bar in bars) {
      expect(bar.max, 100);
      expect(bar.colorFor, isNotNull); // banded green/amber/red
    }
    expect(
        bars.map((b) => b.value), containsAll(<double>[52.0, 80.0, 30.0]));
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    expect(find.text('MEASURED'), findsOneWidget);
    expect(find.text('ESTIMATED'), findsOneWidget);
  });

  testWidgets(
      'a tap on match report content opens plain, read-only chat and never '
      'posts to /report/match/{id}/correct — match has no correction path',
      (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    final chatCalls = <Map<String, dynamic>>[];
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(viewerCanEdit: false),
      correctCalls: correctCalls,
      chatCalls: chatCalls,
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // Long-press never enters selection mode (no quick-actions for match).
    await tester.longPress(
        find.byKey(const ValueKey('livingReportBlock:dim:values:rationale')));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);

    // A short tap opens read-only Q&A chat instead.
    await tester.tap(
        find.byKey(const ValueKey('livingReportBlock:dim:values:rationale')));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Make public'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    await _sendComposer(tester, 'why is this rated so high?');

    expect(correctCalls, isEmpty);
    expect(chatCalls, hasLength(1));
    expect(chatCalls.single['message'], 'why is this rated so high?');
  });

  testWidgets('Copy summary is gone from the report', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Copy summary'), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsNothing);
  });

  testWidgets('Recalculate and Ask Ayma sit in the AppBar', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
    );

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
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
    );

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

  testWidgets(
      'a capped recalc shows an out-of-credits snack with a Reload '
      'action that opens the reload screen', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
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
          matchId: 'a__me', apiClient: _api(matchMeta: null, matchStatus: 404)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("hasn't been scored"), findsOneWidget);
  });
}
