// Tests for MatchReportScreen after it became a thin wrapper around the
// shared LivingReportView (§ generic reports, report_type "match" — see
// report_adapters.match_blocks / report_hub.py). Three things are
// exercised:
// - the ONLY bespoke screen chrome left outside the generic renderer (the
//   two-person avatar row, Recalculate AppBar action), sourced
//   from the existing `GET /match/{id}` fetch — score and confidence used
//   to ALSO render here as a big digit + a separate chip; that duplication
//   (§ founder screenshot) is fixed, and several tests below guard against
//   it coming back (see the GUARDRAIL in `living_report_view.dart`);
// - the whole screen scrolling as ONE region — the avatar chrome is no
//   longer pinned above a separately-scrolling body;
// - the report BODY, fetched separately via `GET /report/match/{id}` and
//   rendered by LivingReportView — including the real-request-body proof
//   that a tap on match content never posts to `/report/match/{id}/correct`
//   (there is no correction path for this report type — see
//   report_hub.py's module docstring) and instead always goes through
//   plain, read-only `/chat`.
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

Future<void> _sendComposer(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
  await tester.pumpAndSettle();
}

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
      'renders the two-person avatar header chrome, with no score digit or '
      'confidence text of its own (§ duplication fix)', (tester) async {
    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('You'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget); // avatar label = first name
    // "52%" used to ALSO print as a big chrome number between the avatars —
    // it doesn't any more. It now shows up exactly once, from the report
    // body's own "Match score" stat block (see the next test).
    expect(find.text('52%'), findsOneWidget);
  });

  testWidgets(
      'confidence band renders exactly once, from the report body\'s stat '
      'block — no separate bespoke confidence chip any more (§ duplication '
      'fix)', (tester) async {
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

    // No standalone "Confidence: <band>" pill in the header any more.
    expect(find.textContaining('Confidence:'), findsNothing);
    // The old chip's note text came from /match metadata, not the block
    // model — it's gone entirely now. The block's own basis text (the
    // fixture's score block: `basis: 'High confidence'`) is the only
    // confidence readout left, and it shows up exactly once.
    expect(find.text('High confidence - both profiles are detailed.'),
        findsNothing);
    expect(find.text('High confidence'), findsOneWidget);
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

    // Chrome (avatar header) and generic block content both visible
    // together — but "52%" itself renders exactly once now, from the
    // adapter's own "score" stat block (§ duplication fix: the header used
    // to ALSO print it).
    expect(find.text('52%'), findsOneWidget);
    expect(find.text('You two line up on the big things.'), findsOneWidget);
    expect(find.text('VALUES & WORLDVIEW'), findsOneWidget);
    expect(find.textContaining('Both prioritize family closely.'),
        findsOneWidget);
  });

  testWidgets(
      'the whole screen scrolls as ONE region — the avatar header chrome '
      'moves with the body instead of staying pinned above it (§ founder: '
      '"Don\'t keep this part frozen, let it also scroll" — the inverse of '
      'the public-profile action rail, which deliberately DOES stay fixed)',
      (tester) async {
    // The file-level `setUp` above sizes the test viewport huge (1200x3200)
    // for other tests' convenience — shrink it to a realistic phone size
    // just for this test so a modest amount of extra content reliably
    // overflows the viewport and there's real scrolling to prove.
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(400, 800);
    addTearDown(
        () => binding.platformDispatcher.views.first.resetPhysicalSize());

    final api = _api(
      matchMeta: matchMeta(),
      livingReport: _livingReport(extraSections: [
        for (var i = 0; i < 12; i++)
          {
            'heading': 'Dimension $i',
            'blocks': [
              {
                'block_id': 'dim:extra$i',
                'type': 'fact',
                'editable': false,
                'text': 'Rationale paragraph for dimension $i. ' * 10,
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

    // A MODEST, exact scroll via the controller (not `tester.drag`, whose
    // release fling would carry well past any requested distance) — enough
    // to move the header, not so much it scrolls clean out of the list's
    // cache extent and gets unmounted. Unlike the pinned action rail this
    // mirrors, the header is a normal scrollable list item, not an
    // always-mounted Stack sibling.
    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final before = position.pixels;
    // A small, exact jump — well under the header card's own height — so
    // it's still partially on screen afterwards (definitely still mounted,
    // not just within some cache-extent guess) while its rect still
    // measurably moves.
    position.jumpTo(before + 60);
    await tester.pump();
    final after = position.pixels;
    // Confirm there was actually something to scroll through, otherwise
    // this test would pass vacuously.
    expect(after, greaterThan(before));

    // Unlike the profile action rail (deliberately pinned), the header card
    // is NOT a sibling of the scrollable body — it's the body's own first
    // item — so its on-screen position must have moved once the body
    // scrolled underneath it.
    final rectAfterScroll = tester.getRect(header);
    expect(rectAfterScroll, isNot(rectBeforeScroll));
  });

  testWidgets(
      'dimension stat blocks render real banded ScoreBars end to end (§ '
      'founder: the match report lost its graphics after the Living Report '
      'migration — this is the fix); the header chrome carries none of '
      'these itself — every stat bar is block-rendered', (tester) async {
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

    // The header carries no score digit of its own any more (§ duplication
    // fix) — the body's own top-line "Match score" stat block (from
    // `_livingReport()`'s "Match" section) is itself a numeric stat getting
    // the exact same generic bar treatment as the dimensions below it:
    // score (52%) + dim:values (80) + dim:interests (30) = 3.
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
    expect(find.text('Ask Ayma'), findsWidgets);
    expect(
        find.text("Ask a question, or tell Ayma what to change."),
        findsOneWidget);
    expect(find.text('Make public'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    await _sendComposer(tester, 'why is this rated so high?');

    expect(correctCalls, isEmpty);
    expect(chatCalls, hasLength(1));
    expect(chatCalls.single['message'], 'why is this rated so high?');
    // `match_report_id` still rides along on the real /chat request body
    // (`AskAymaContext.matchReportId`, wired in `LivingReportView._open`)
    // even though this is the read-only `reportView` origin with
    // `report_type`/`report_id` deliberately left blank — see
    // `_match_edit_context` in main.py for what this briefs Ayma to do with
    // it (correct the underlying fact, then point at Recalculate).
    expect(chatCalls.single['match_report_id'], 'a__me');
    expect(chatCalls.single['deep_dive_report_id'], '');
    expect(chatCalls.single['appearance_finding_id'], '');
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

  testWidgets('Recalculate (and no Ask Ayma button) sits in the AppBar', (tester) async {
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
        findsNothing);
    expect(find.descendant(of: inAppBar, matching: find.text('Copy summary')),
        findsNothing);
  });

  testWidgets(
      'tapping Recalculate in the AppBar still triggers the same '
      'recalculation flow (force re-run, then reload BOTH the /match '
      'metadata AND the Living Report body — the score only ever renders '
      'from the latter now, § duplication fix)', (tester) async {
    // Non-queued (immediate) recalc path: no MatchActivity polling involved,
    // so this can't leak background state into later tests. Returns a
    // different score on the second fetch of each endpoint to prove BOTH
    // reloaded — the header no longer has its own score digit to fall back
    // on, so if the Living Report body isn't explicitly reloaded too, "71%"
    // would never appear at all.
    var matchCalls = 0;
    var reportCalls = 0;
    final compatCalls = <bool>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/check-compatibility') {
          compatCalls.add(jsonDecode(req.body)['force'] == true);
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (req.url.path == '/report/match/a__me') {
          reportCalls++;
          final score = reportCalls == 1 ? '52%' : '71%';
          return http.Response(
            jsonEncode(_livingReport()
              ..['sections'][0]['blocks'][0]['value'] = score),
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8'
            },
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
    expect(find.text('52%'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(compatCalls, [true]); // called with force: true
    expect(reportCalls, greaterThanOrEqualTo(2)); // Living Report reloaded
    expect(find.text('71%'), findsOneWidget); // report reloaded
    expect(find.text('52%'), findsNothing); // stale value gone
  });

  testWidgets(
      'a capped recalc shows an out-of-credits toast with an Upgrade '
      'action that opens the plans screen', (tester) async {
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

    expect(find.text("You're out of credits"), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
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
