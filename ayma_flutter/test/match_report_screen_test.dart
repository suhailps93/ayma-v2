// Tests for MatchReportScreen after it was migrated to render its report BODY
// through the shared [GraphTreeView] Node-Visualiser (2o P3) via
// `GET /report/match/{id}/tree` — the SAME pattern the appearance and
// deep-dive report screens use. The old LivingReportView body was deleted.
//
// This file exercises the SCREEN wiring and the match-specific chrome:
// - the only bespoke chrome left outside the generic renderer (the two-person
//   avatar row + the Recalculate/Share AppBar actions), sourced from the
//   existing `GET /match/{id}` fetch — score/confidence used to ALSO render
//   here as a big digit + a separate chip; that duplication (§ founder
//   screenshot) is fixed and guarded against below;
// - the whole screen scrolling as ONE region;
// - the report BODY, fetched separately via `GET /report/match/{id}/tree` and
//   rendered by the Node-Visualiser — the score + dimensions as banded
//   ScoreBars (founder: the match report must not "lose its graphics"), and a
//   non-participant / never-scored pair getting the empty state, never a score.
//
// Per-node render + tap behavior (the read-only report node chat, the stat
// bar vs confidence pill, candidate verdicts) is covered once, generically, in
// `node_visualiser_test.dart`; this file proves the screen wires the right
// report id/type and that its own chrome still works.
import 'dart:convert';

import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/match_report_cache.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// A minimal but real Node-Visualiser tree shaped like
/// `report_tree.report_node_tree`'s real output for a match — the top-line
/// "Match score" as a numeric stat (its "52%" string is parsed to a 0..100
/// ScoreBar by `report_tree._percent_value`), an explanation text node, and one
/// dimension section with its own numeric stat + rationale. `viewer_can_edit`
/// is always false (match reports have no correction path at all).
Map<String, dynamic> _tree({
  double score = 52.0,
  String scoreText = '52%',
  List<Map<String, dynamic>>? extraSections,
}) => {
      'surface': 'report',
      'title': 'Match with Sam Vale',
      'sections': [
        {
          'page_type': 'match',
          'title': 'Match',
          'order': 0,
          'nodes': [
            {
              'id': 'score',
              'section': 'match',
              'label': 'Match score',
              'text': 'Match score',
              'answer_type': 'stat',
              'stat_value': score,
              'stat_text': scoreText,
              'stat_basis': 'High confidence',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
            {
              'id': 'explanation:sent:0',
              'section': 'match',
              'label': '',
              'text': 'You two line up on the big things.',
              'answer_type': 'text',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
          ],
        },
        {
          'page_type': 'values_worldview',
          'title': 'Values & worldview',
          'order': 1,
          'nodes': [
            {
              'id': 'dim:values',
              'section': 'values_worldview',
              'label': 'Values & worldview',
              'text': 'Values & worldview',
              'answer_type': 'stat',
              'stat_value': 80.0,
              'stat_text': '80',
              'stat_basis': '22% weight · measured',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
            {
              'id': 'dim:values:rationale',
              'section': 'values_worldview',
              'label': '',
              'text': 'Both prioritize family closely.',
              'answer_type': 'text',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
          ],
        },
        ...?extraSections,
      ],
      'meta': {
        'owner_uid': 'me',
        'viewer_can_edit': false,
        'created_at': null,
        'updated_at': null,
      },
    };

ApiClient _api({
  Map<String, dynamic>? matchMeta,
  int matchStatus = 200,
  Map<String, dynamic>? compat,
  Map<String, dynamic>? tree,
  int treeStatus = 200,
  List<Map<String, dynamic>>? correctCalls,
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
      if (req.method == 'GET' && req.url.path == '/report/match/a__me/tree') {
        return http.Response(
          treeStatus == 200 ? jsonEncode(tree ?? _tree()) : 'no',
          treeStatus,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // Match reports are read-only — a correct POST must never happen.
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
      return http.Response('{}', 200);
    }),
  );
}

/// A GoRouter host so `context.push('/profile/plan')` from the out-of-credits
/// toast has somewhere to land.
Widget _routed(Widget screen) => MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/match/a__me',
        routes: [
          GoRoute(path: '/match/a__me', builder: (_, __) => screen),
          GoRoute(
            path: '/profile/plan',
            builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
          ),
        ],
      ),
    );

void main() {
  setUp(() {
    // BUG F: the session report cache is a singleton — clear it so one case's
    // cached header never paints in the next (e.g. the never-scored case).
    MatchReportCache.instance.reset();
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

  testWidgets(
      'renders the two-person avatar header chrome, with no bespoke score '
      'digit or confidence chip of its own (§ duplication fix)', (tester) async {
    final api = _api(matchMeta: matchMeta(), tree: _tree());

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('You'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget); // avatar label = first name
    // No standalone "Confidence: <band>" pill in the header any more; the
    // confidence reads once, from the body's "Match score" stat basis.
    expect(find.textContaining('Confidence:'), findsNothing);
    expect(find.text('High confidence'), findsOneWidget);
  });

  testWidgets(
      'the report body renders via the Node-Visualiser tree from '
      'GET /report/match/{id}/tree', (tester) async {
    final api = _api(matchMeta: matchMeta(), tree: _tree());

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('You two line up on the big things.'), findsOneWidget);
    // Section titles render as-is from the tree (not uppercased).
    expect(find.text('Values & worldview'), findsWidgets);
    expect(find.text('Both prioritize family closely.'), findsOneWidget);
  });

  testWidgets(
      'the score and each dimension render as banded ScoreBars end to end (§ '
      'founder: the match report must not lose its graphics); every stat bar '
      'is body-rendered — the header carries none', (tester) async {
    final api = _api(matchMeta: matchMeta(), tree: _tree());

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // The top-line "Match score" (52) and the dimension (80) both get the
    // generic banded 0..100 bar treatment.
    final bars = tester.widgetList<ScoreBar>(find.byType(ScoreBar)).toList();
    expect(bars, hasLength(2));
    for (final bar in bars) {
      expect(bar.max, 100);
      expect(bar.colorFor, isNotNull); // banded green/amber/red
    }
    expect(bars.map((b) => b.value), containsAll(<double>[52.0, 80.0]));
    // The numeric digits show beside each bar (no "%" suffix — the shipped
    // Node-Visualiser convention the appearance/deep-dive screens already use).
    expect(find.text('52'), findsOneWidget);
    expect(find.text('80'), findsOneWidget);
  });

  testWidgets(
      'the whole screen scrolls as ONE region — the avatar header chrome '
      'moves with the body instead of staying pinned above it (§ founder: '
      '"Don\'t keep this part frozen, let it also scroll")', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(400, 800);
    addTearDown(
        () => binding.platformDispatcher.views.first.resetPhysicalSize());

    final api = _api(
      matchMeta: matchMeta(),
      tree: _tree(extraSections: [
        for (var i = 0; i < 12; i++)
          {
            'page_type': 'dim_$i',
            'title': 'Dimension $i',
            'order': i + 2,
            'nodes': [
              {
                'id': 'dim:extra$i',
                'section': 'dim_$i',
                'label': '',
                'text': 'Rationale paragraph for dimension $i. ' * 10,
                'answer_type': 'text',
                'level': 1,
                'visibility': 'public',
                'subtree_visibility': 'public',
                'editable': false,
              },
            ],
          },
      ]),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    final header = find.byKey(const ValueKey('matchHeaderCard'));
    expect(header, findsOneWidget);
    final rectBeforeScroll = tester.getRect(header);

    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final before = position.pixels;
    position.jumpTo(before + 60);
    await tester.pump();
    final after = position.pixels;
    expect(after, greaterThan(before));

    final rectAfterScroll = tester.getRect(header);
    expect(rectAfterScroll, isNot(rectBeforeScroll));
  });

  testWidgets(
      'tapping a match report node opens the read-only node sheet — no edit '
      'bubbles — and never posts to /report/match/{id}/correct (match has no '
      'correction path)', (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    final api = _api(
      matchMeta: matchMeta(),
      tree: _tree(),
      correctCalls: correctCalls,
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('node_row_dim:values:rationale')));
    await tester.pumpAndSettle();

    // A non-editable report node: no owner edit bubbles at all.
    expect(find.text('Make public'), findsNothing);
    expect(find.text('Make private'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    // And nothing ever routes to the correction endpoint.
    expect(correctCalls, isEmpty);
  });

  testWidgets("the AppBar title always reads 'Match report'", (tester) async {
    final api = _api(matchMeta: matchMeta(), tree: _tree());
    await tester.pumpWidget(
        MaterialApp(home: MatchReportScreen(matchId: 'a__me', apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Match report'), findsOneWidget);
    expect(find.text('Compatibility'), findsNothing);
  });

  testWidgets('Recalculate (and no Ask Ayma button) sits in the AppBar',
      (tester) async {
    final api = _api(matchMeta: matchMeta(), tree: _tree());

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    final inAppBar = find.byType(AppBar);
    expect(find.descendant(of: inAppBar, matching: find.byIcon(Icons.refresh)),
        findsOneWidget);
    expect(find.descendant(of: inAppBar, matching: find.text('Ask Ayma')),
        findsNothing);
    expect(find.descendant(of: inAppBar, matching: find.text('Copy summary')),
        findsNothing);
  });

  testWidgets(
      'tapping Recalculate force-re-runs then reloads BOTH the /match metadata '
      'AND the Node-Visualiser body — the score only ever renders from the '
      'latter now (§ duplication fix)', (tester) async {
    var matchCalls = 0;
    var treeCalls = 0;
    final compatCalls = <bool>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/check-compatibility') {
          compatCalls.add(jsonDecode(req.body)['force'] == true);
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (req.url.path == '/report/match/a__me/tree') {
          treeCalls++;
          // A different score on the second load proves the body reloaded.
          return http.Response(
            jsonEncode(treeCalls == 1
                ? _tree(score: 52.0, scoreText: '52%')
                : _tree(score: 71.0, scoreText: '71%')),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
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
    expect(find.text('52'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(compatCalls, [true]); // called with force: true
    expect(treeCalls, greaterThanOrEqualTo(2)); // body reloaded
    expect(find.text('71'), findsOneWidget); // report reloaded
    expect(find.text('52'), findsNothing); // stale value gone
  });

  testWidgets(
      'a capped recalc shows an out-of-credits toast with an Upgrade action '
      'that opens the plans screen', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      tree: _tree(),
      compat: {'ok': false, 'usage_capped': true},
    );

    await tester.pumpWidget(_routed(
      MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text("You're out of credits"), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
    await tester.pumpAndSettle();
    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets(
      'the error-state Retry button has a >= 48 tall touch target (Jobs pass)',
      (tester) async {
    // GET /match always fails → after the silent retries exhaust, the
    // "Couldn't load this report." / Retry error state shows.
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/match/a__me') {
          return http.Response('down', 503);
        }
        if (req.url.path == '/chat/stream') {
          return http.Response('stream unavailable', 500);
        }
        return http.Response('{}', 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    final h = tester.getSize(find.widgetWithText(TextButton, 'Retry')).height;
    expect(h, greaterThanOrEqualTo(48.0));
  });

  testWidgets('a never-scored pair shows the empty state (no score leaked)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(
          matchId: 'a__me', apiClient: _api(matchMeta: null, matchStatus: 404)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("hasn't been scored"), findsOneWidget);
  });

  testWidgets(
      'a non-participant whose /report/match/{id}/tree 404s gets the body '
      'empty state, never a score (owner-only read preserved end to end)',
      (tester) async {
    // The /match chrome fetch happens to resolve (e.g. a stale score the
    // participant once had), but the tree — the actual report content — 404s.
    // The body must show the empty CTA, never any score digit/bar.
    final api = _api(
      matchMeta: matchMeta(),
      treeStatus: 404,
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Nothing to show for this report yet.'), findsOneWidget);
    expect(find.byType(ScoreBar), findsNothing);
    expect(find.text('52'), findsNothing);
    expect(find.text('You two line up on the big things.'), findsNothing);
  });

  testWidgets(
      'the taste card is present and reachable in the report scroll (never '
      'skipped)', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(400, 800);
    addTearDown(
        () => binding.platformDispatcher.views.first.resetPhysicalSize());

    final meta = {
      ...matchMeta(),
      'taste': {
        'status': 'ok',
        'source': 'qloo',
        'score': 68,
        'score_label': 'Good taste overlap',
        'summary': 'You both lean dreamy psych-rock.',
        'shared': ['Khruangbin'],
        'domains': [
          {'domain': 'music', 'score': 70},
          {'domain': 'film', 'score': 66},
        ],
        'date_ideas': [
          {'name': 'Tartine', 'kind': 'dining', 'why': 'Ranked for both of you.'},
        ],
      },
    };
    final api = _api(
      matchMeta: meta,
      tree: _tree(extraSections: [
        for (var i = 0; i < 12; i++)
          {
            'page_type': 'dim_$i',
            'title': 'Dimension $i',
            'order': i + 2,
            'nodes': [
              {
                'id': 'dim:x$i',
                'section': 'dim_$i',
                'label': '',
                'text': 'Rationale $i. ' * 12,
                'answer_type': 'text',
                'level': 1,
                'visibility': 'public',
                'subtree_visibility': 'public',
                'editable': false,
              },
            ],
          },
      ]),
    );

    await tester.pumpWidget(
        MaterialApp(home: MatchReportScreen(matchId: 'a__me', apiClient: api)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('tasteMatchCard')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('tasteMatchCard')), findsOneWidget);
    expect(find.text('powered by Qloo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'founder 2026-11-01 regression: tapping a Match report whose GET '
      '/match/{id} transiently fails twice then succeeds auto-recovers — the '
      '"Couldn\'t load this report." / Retry screen never appears, the report '
      'just loads', (tester) async {
    var seen = 0;
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.method == 'GET' && req.url.path == '/match/a__me') {
          seen++;
          if (seen <= 2) return http.Response('transient', 503);
          return http.Response(jsonEncode(matchMeta()), 200);
        }
        if (req.method == 'GET' && req.url.path == '/report/match/a__me/tree') {
          return http.Response(
            jsonEncode(_tree()),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/chat/stream') {
          return http.Response('stream unavailable', 500);
        }
        return http.Response('{}', 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load this report"), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('You two line up on the big things.'), findsOneWidget);
    expect(seen, 3); // Initial GET + 2 silent retries, the third succeeding.
    expect(tester.takeException(), isNull);
  });
}
