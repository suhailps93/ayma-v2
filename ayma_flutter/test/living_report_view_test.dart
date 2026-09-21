// Tests for the ONE shared Living Report renderer (§ generic reports):
// - the three tap tiers (block/section/report) each produce the correct
//   `{block_ids, scope}` in the REAL outgoing `POST /report/.../correct`
//   request body (inspected via a mocked ApiClient's HTTP layer, not a
//   fake subclass standing in for it — same rigor as
//   `ask_ayma_overlay_wire_body_test.dart`);
// - ad-hoc multi-select bundles block ids from any combination of blocks;
// - quick-action chips: candidate blocks get "This is me"/"Not me", normal
//   editable blocks get make-public/make-private + "Delete";
// - quick actions / selection are unavailable when `viewer_can_edit` is
//   false, and a tap there never calls the correct endpoint;
// - a text-block sentence responds to a bare short tap exactly like any
//   other block type (§ regression fix — this used to be long-press-only,
//   which read as narrative prose being entirely non-tappable).
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/living_report_view.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _report({
  bool viewerCanEdit = true,
  // Extra padding facts so the section list overflows the test viewport and
  // is actually draggable (§ scroll-position tests below).
  int extraFacts = 0,
  // Mirrors `report_adapters.deep_dive_blocks`'s real "Links" (from
  // `digest.links`, block ids keyed by url) and "Social profiles" (from
  // `digest.social_handles`) sections — both `editable: true` on the real
  // backend after the fix (§ `dispute_link`); this fixture reproduces that
  // exact shape rather than guessing at it.
  bool includeLinksAndSocial = false,
}) =>
    {
      'title': 'Web search: Jane',
      'sections': [
        {
          'heading': 'Summary',
          'blocks': [
            {
              'block_id': 'summary:sent:0',
              'type': 'text',
              'editable': true,
              'text': 'Jane works at Acme.',
            },
            {
              'block_id': 'summary:sent:1',
              'type': 'text',
              'editable': true,
              'text': 'She lives in Austin.',
            },
          ],
        },
        {
          'heading': 'Facts',
          'blocks': [
            {
              'block_id': 'fact:1',
              'type': 'fact',
              'editable': true,
              'text': 'Graduated in 2020.',
              'tag': 'education',
              'confidence': 'high',
            },
            for (var i = 0; i < extraFacts; i++)
              {
                'block_id': 'fact:extra:$i',
                'type': 'fact',
                'editable': true,
                'text': 'Extra padding fact number $i.',
                'tag': 'padding',
                'confidence': 'low',
              },
          ],
        },
        {
          'heading': 'Photos to confirm',
          'blocks': [
            {
              'block_id': 'candidate:c1',
              'type': 'photo',
              'editable': true,
              'url': 'https://example.invalid/c1.png',
              'status': 'pending',
            },
          ],
        },
        if (includeLinksAndSocial) ...[
          {
            'heading': 'Links',
            'blocks': [
              {
                'block_id': 'link:https://github.com/suhailps93',
                'type': 'link',
                'editable': true,
                'url': 'https://github.com/suhailps93',
                'label': 'GitHub Profile',
              },
            ],
          },
          {
            'heading': 'Social profiles',
            'blocks': [
              {
                'block_id': 'social:https://instagram.com/suhail.p.sulaiman',
                'type': 'link',
                'editable': true,
                'url': 'https://instagram.com/suhail.p.sulaiman',
                'label': '@suhail.p.sulaiman',
              },
            ],
          },
        ],
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': viewerCanEdit,
        'created_at': null,
        'updated_at': null,
      },
    };

/// A real [ApiClient] over a [MockClient] that serves `GET
/// /report/deep_dive/rid1`, records every `POST /report/deep_dive/rid1
/// /correct` body into [correctCalls], and serves a plain `/chat` fallback
/// (`/chat/stream` made to fail, same trick every Ask-Ayma test in this app
/// uses) recording into [chatCalls] for the non-owner read-only path.
ApiClient _api({
  bool viewerCanEdit = true,
  List<Map<String, dynamic>>? correctCalls,
  List<Map<String, dynamic>>? chatCalls,
  String correctReply = 'Got it — updated.',
  int extraFacts = 0,
  bool includeLinksAndSocial = false,
  // Every `GET /report/deep_dive/rid1` (initial load + every `reload()`)
  // appends here — lets a test prove a reload did or didn't happen, not
  // just infer it from side effects.
  List<int>? getCallLog,
}) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/report/deep_dive/rid1') {
      getCallLog?.add(1);
      return http.Response(
        jsonEncode(_report(
          viewerCanEdit: viewerCanEdit,
          extraFacts: extraFacts,
          includeLinksAndSocial: includeLinksAndSocial,
        )),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.method == 'POST' &&
        request.url.path == '/report/deep_dive/rid1/correct') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      correctCalls?.add(body);
      final ids = (body['block_ids'] as List).cast<String>();
      return http.Response(
        jsonEncode({
          'ok': true,
          'results': [
            for (final id in ids)
              {'block_id': id, 'ok': true, 'reply': correctReply},
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.url.path == '/chat/stream') {
      return http.Response('stream unavailable', 500);
    }
    if (request.url.path == '/chat') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      chatCalls?.add(body);
      return http.Response(
        jsonEncode({'reply': 'Sure, ask away.', 'usage_capped': false}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(ApiClient api) => MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'deep_dive',
          reportId: 'rid1',
          apiClient: api,
        ),
      ),
    );

Future<void> _sendComposer(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
  await tester.pumpAndSettle();
}

// --- Appearance report: Attributes source photos (§ regression fix) -------
//
// The Attributes section used to show a row of small photo thumbnails —
// "which photos were actually used" for the structured attribute read —
// under the "ATTRIBUTES" heading. After the migration onto this shared
// renderer those thumbnails briefly went missing (the backend adapter never
// turned `attributes.source_photos` into a block at all). This confirms the
// fix end to end: a `photo_grid` block under "Attributes" renders as an
// actual row of `Image.network` thumbnails, same as Face/Body's own single
// `photo` block.

Map<String, dynamic> _appearanceReport() => {
      'title': 'Appearance',
      'sections': [
        {
          'heading': 'Attributes',
          'blocks': [
            {
              'block_id': 'attr:eye_color',
              'type': 'attribute',
              'editable': true,
              'label': 'Eye color',
              'value': 'brown',
            },
            {
              'block_id': 'attr:photos',
              'type': 'photo_grid',
              'editable': false,
              'photos': [
                {'url': 'https://cdn.example/a.jpg'},
                {'url': 'https://cdn.example/b.jpg'},
                {'url': 'https://cdn.example/c.jpg'},
              ],
            },
          ],
        },
        {
          'heading': 'Face',
          'blocks': [
            {
              // § founder: the score is Ayma's own algorithmic verdict, not
              // user-editable via tap-to-chat — `editable: false`, same as
              // Match's score and Face/Body's own source photo below.
              'block_id': 'face',
              'type': 'stat',
              'editable': false,
              'label': 'Above average',
              'value': 7.5,
            },
            {
              'block_id': 'face:photo',
              'type': 'photo',
              'editable': false,
              'url': 'https://cdn.example/face.jpg',
            },
          ],
        },
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        'created_at': null,
        'updated_at': null,
      },
    };

ApiClient _appearanceApi() {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/report/appearance/u1') {
      return http.Response(
        jsonEncode(_appearanceReport()),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

// --- `stat` block: real ScoreBar instead of plain digits (§ founder: "the
// match report lost all its graphics") -------------------------------------
//
// A `stat` block carries no explicit `max` in the wire shape
// (`report_blocks.stat_block`), so the renderer infers 0-10 vs 0-100 from
// the value/basis shape each real producer actually sends — see
// `_StatRow._impliedMax`'s doc in `living_report_view.dart`. These fixtures
// mirror the three real shapes: Face/Body's 0-10 rating (`appearance_blocks`
// -> `scored_result_blocks`), Match's 0-100 weighted dimension score
// (`report_adapters.match_blocks`), and deep-dive's word-valued Confidence
// stat (non-numeric — no bar at all).

Map<String, dynamic> _matchDimReport() => {
      'title': 'Match with Alex',
      'sections': [
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
          ],
        },
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
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': false,
        'created_at': null,
        'updated_at': null,
      },
    };

Map<String, dynamic> _confidenceStatReport() => {
      'title': 'Web search: Jane',
      'sections': [
        {
          'heading': 'Summary',
          'blocks': [
            {
              'block_id': 'confidence',
              'type': 'stat',
              'editable': false,
              'label': 'Confidence',
              'value': 'High',
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

ApiClient _reportApi(String reportType, String reportId, Map<String, dynamic> report) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' &&
        request.url.path == '/report/$reportType/$reportId') {
      return http.Response(
        jsonEncode(report),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

// --- Story narrative prose: realistic multi-sentence tap-to-edit
// regression (§ founder screenshot: a serif paragraph reading "His full
// name is Suhail Pallath Sulaiman. Born in Dubai, he moved to Kerala..."
// that he reported as "not clickable to edit") ------------------------------
//
// One section, one genuinely multi-sentence narrative passage, split into
// one `text` block per sentence exactly the way the real backend does it
// (`report_adapters._story_section_blocks` -> `report_blocks.
// split_sentences`) — not a single short trivial string, so this actually
// exercises `_ProseFlow`'s multi-block flow layout, not a degenerate
// one-sentence case.

Map<String, dynamic> _storyNarrativeReport() => {
      'title': 'Your Story',
      'sections': [
        {
          'heading': 'Identity',
          'blocks': [
            {
              'block_id': 'page:identity:sent:0',
              'type': 'text',
              'editable': true,
              'text': 'His full name is Suhail Pallath Sulaiman.',
            },
            {
              'block_id': 'page:identity:sent:1',
              'type': 'text',
              'editable': true,
              'text': 'Born in Dubai, he moved to Kerala at age seven, then '
                  'returned for university.',
            },
            {
              'block_id': 'page:identity:sent:2',
              'type': 'text',
              'editable': true,
              'text': 'He now works as a software engineer specializing in '
                  'distributed systems.',
            },
          ],
        },
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        'created_at': null,
        'updated_at': null,
      },
    };

ApiClient _storyNarrativeApi({List<Map<String, dynamic>>? correctCalls}) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/report/story_private/u1') {
      return http.Response(
        jsonEncode(_storyNarrativeReport()),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.method == 'POST' &&
        request.url.path == '/report/story_private/u1/correct') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      correctCalls?.add(body);
      final ids = (body['block_ids'] as List).cast<String>();
      return http.Response(
        jsonEncode({
          'ok': true,
          'results': [
            for (final id in ids) {'block_id': id, 'ok': true, 'reply': 'Updated.'},
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.url.path == '/chat/stream') {
      return http.Response('stream unavailable', 500);
    }
    if (request.url.path == '/chat') {
      return http.Response(
        jsonEncode({'reply': 'Sure.', 'usage_capped': false}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets(
      "the Attributes section's photo_grid block renders every source "
      "photo as a network image thumbnail, and Face's own single photo "
      'block still renders too', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'appearance',
          reportId: 'u1',
          apiClient: _appearanceApi(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('ATTRIBUTES'), findsOneWidget);
    expect(find.text('FACE'), findsOneWidget);

    // Thumbnails now render through AymaPhoto/CachedNetworkImage (cached +
    // decoded at thumbnail size) rather than a plain Image.network — see
    // the "reads the whole HD picture every time" perf fix.
    final networkImages = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .map((w) => w.imageUrl)
        .toSet();
    expect(networkImages, containsAll(<String>[
      'https://cdn.example/a.jpg',
      'https://cdn.example/b.jpg',
      'https://cdn.example/c.jpg',
      'https://cdn.example/face.jpg',
    ]));
  });

  testWidgets(
      "Face's overall-score stat block renders a real flat/accent ScoreBar "
      'out of 10, not plain digits', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'appearance',
          reportId: 'u1',
          apiClient: _appearanceApi(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final bar = tester.widget<ScoreBar>(find.byType(ScoreBar));
    expect(bar.value, 7.5);
    expect(bar.max, 10);
    expect(bar.colorFor, isNull); // flat mode, not banded
    expect(find.text('7.5/10'), findsOneWidget);
  });

  testWidgets(
      "tapping Face's overall-score block opens nothing at all — it's "
      "Ayma's own algorithmic verdict (§ founder: user should NOT be able "
      'to change the score), same as an editable:false photo/Match block, '
      'never the Make-public/Delete chat', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'appearance',
          reportId: 'u1',
          apiClient: _appearanceApi(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:face')));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsNothing);
    expect(find.text('Make public'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    // Long-press (multi-select entry) is inert on it too, same as any other
    // non-editable block.
    await tester.longPress(find.byKey(const ValueKey('livingReportBlock:face')));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets(
      "Match's per-dimension stat blocks render banded ScoreBars out of "
      '100, and the measured/estimated source label renders as a distinct '
      'colored tag instead of plain gray text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'match',
          reportId: 'm1',
          apiClient: _reportApi('match', 'm1', _matchDimReport()),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final bars = tester.widgetList<ScoreBar>(find.byType(ScoreBar)).toList();
    expect(bars, hasLength(2));
    for (final bar in bars) {
      expect(bar.max, 100);
      expect(bar.colorFor, isNotNull); // banded mode
    }
    expect(bars.map((b) => b.value), containsAll(<double>[80.0, 30.0]));

    expect(find.text('80%'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    expect(find.text('22% weight'), findsOneWidget);
    expect(find.text('MEASURED'), findsOneWidget);
    expect(find.text('ESTIMATED'), findsOneWidget);
  });

  testWidgets(
      'a non-numeric stat value (deep-dive Confidence) renders a colored '
      'band pill instead of a ScoreBar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'deep_dive',
          reportId: 'd1',
          apiClient: _reportApi('deep_dive', 'd1', _confidenceStatReport()),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ScoreBar), findsNothing);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Confidence'), findsOneWidget);
  });

  testWidgets('renders the title, section headings and block content',
      (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    expect(find.text('Web search: Jane'), findsOneWidget);
    expect(find.text('SUMMARY'), findsOneWidget);
    expect(find.text('FACTS'), findsOneWidget);
    expect(find.text('PHOTOS TO CONFIRM'), findsOneWidget);
    expect(find.textContaining('Graduated in 2020.'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
  });

  testWidgets('tapping the report title sends scope "report" with every block id',
      (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(correctCalls: correctCalls)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportTitle')));
    await tester.pumpAndSettle();
    await _sendComposer(tester, 'what is this about');

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'report');
    expect(correctCalls.single['block_ids'], containsAll(<String>[
      'summary:sent:0', 'summary:sent:1', 'fact:1', 'candidate:c1',
    ]));
    expect(correctCalls.single['message'], 'what is this about');
  });

  testWidgets(
      'tapping a section heading sends scope "section" with just that '
      "section's block ids", (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(correctCalls: correctCalls)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportSection:Summary')));
    await tester.pumpAndSettle();
    await _sendComposer(tester, 'tidy this up');

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'section');
    expect(correctCalls.single['block_ids'],
        unorderedEquals(<String>['summary:sent:0', 'summary:sent:1']));
  });

  testWidgets(
      'a short tap on a non-text block sends scope "block" for just that one',
      (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(correctCalls: correctCalls)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:fact:1')));
    await tester.pumpAndSettle();
    await _sendComposer(tester, "that's wrong");

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'block');
    expect(correctCalls.single['block_ids'], ['fact:1']);
  });

  testWidgets(
      'a bare short tap on a text-block sentence opens Edit-with-Ayma for '
      'just that sentence, exactly like any other block type (§ regression: '
      'this used to be long-press-only, so narrative prose read as entirely '
      'non-tappable under a normal single tap — the founder\'s "this font is '
      'not clickable to edit" report)', (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(correctCalls: correctCalls)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:summary:sent:0')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    await _sendComposer(tester, 'she works at a different company now');

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'block');
    expect(correctCalls.single['block_ids'], ['summary:sent:0']);
  });

  testWidgets(
      'regression: tapping one sentence within a genuine multi-sentence '
      'Story narrative passage opens Edit-with-Ayma scoped to just that '
      'sentence — reproduces the founder\'s screenshot ("His full name is '
      'Suhail Pallath Sulaiman. Born in Dubai, he moved to Kerala...") '
      'showing serif narrative prose that was not clickable to edit',
      (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'story_private',
          reportId: 'u1',
          apiClient: _storyNarrativeApi(correctCalls: correctCalls),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The whole passage renders as one continuous flowing paragraph...
    expect(
      find.textContaining('Born in Dubai, he moved to Kerala'),
      findsOneWidget,
    );

    // ...but each sentence is its own tap target. A bare tap on the SECOND
    // sentence must open the edit flow scoped to exactly that sentence's
    // block id — not the whole paragraph, and not nothing.
    await tester
        .tap(find.byKey(const ValueKey('livingReportBlock:page:identity:sent:1')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    await _sendComposer(tester, 'he actually moved at age five, not seven');

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'block');
    expect(correctCalls.single['block_ids'], ['page:identity:sent:1']);
    expect(correctCalls.single['message'],
        'he actually moved at age five, not seven');
  });

  testWidgets(
      'long-pressing one block enters selection mode with a checkbox and the '
      'bottom bar; tapping a second block adds it; "Chat about these" bundles '
      'both block ids under scope "block"', (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(correctCalls: correctCalls)));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('livingReportBlock:fact:1')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // Now in selection mode: a plain tap on the sentence toggles it too.
    await tester.tap(find.byKey(const ValueKey('livingReportBlock:summary:sent:0')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Chat about these'));
    await tester.pumpAndSettle();
    await _sendComposer(tester, 'about both of these');

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'block');
    expect(correctCalls.single['block_ids'],
        unorderedEquals(<String>['fact:1', 'summary:sent:0']));
  });

  testWidgets('"Cancel" exits selection mode without opening chat',
      (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('livingReportBlock:fact:1')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Edit with Ayma'), findsNothing);
  });

  testWidgets(
      'a normal editable block offers make-public/make-private + Delete',
      (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:fact:1')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Make public'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('This is me'), findsNothing);
  });

  testWidgets(
      'a pending candidate block offers "This is me" / "Not me" instead',
      (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:candidate:c1')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('This is me'), findsOneWidget);
    expect(find.text('Not me'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Make public'), findsNothing);
  });

  testWidgets('tapping "This is me" sends the exact fixed phrase',
      (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(correctCalls: correctCalls)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:candidate:c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This is me'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['message'], 'This is me');
    expect(correctCalls.single['block_ids'], ['candidate:c1']);
  });

  testWidgets(
      'when viewer_can_edit is false: no quick-action chips, long-press does '
      'nothing, and a typed message goes through plain /chat — never the '
      'correct endpoint', (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    final chatCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(
      viewerCanEdit: false,
      correctCalls: correctCalls,
      chatCalls: chatCalls,
    )));
    await tester.pumpAndSettle();

    // Long-press never enters selection mode for a non-owner.
    await tester.longPress(find.byKey(const ValueKey('livingReportBlock:fact:1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);

    // A short tap still opens a plain, read-only chat about the content.
    await tester.tap(find.byKey(const ValueKey('livingReportBlock:fact:1')));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Make public'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    await _sendComposer(tester, 'who found this?');

    expect(correctCalls, isEmpty);
    expect(chatCalls, hasLength(1));
    expect(chatCalls.single['message'], 'who found this?');
  });

  testWidgets('shows a retry message when the report fails to load',
      (tester) async {
    final mockHttp = MockClient((request) async => http.Response('nope', 404));
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load that report"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  // --- "Links" vs "Social profiles" tappability (§ bug 2) -------------------
  //
  // Reproduces the founder's screenshot exactly: a "Links" section (GitHub
  // Profile, etc, from `digest.links`) sitting right above a "Social
  // profiles" section (from `digest.social_handles`) — both should open the
  // Edit-with-Ayma chat on tap and send the correct block id, since the real
  // backend now marks both `editable: true` (§ `report_adapters.deep_dive_
  // blocks` + `deep_dive.dispute_link`).

  testWidgets('a "Links" block is tappable for edit, same as a "Social '
      'profiles" block', (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(
      correctCalls: correctCalls,
      includeLinksAndSocial: true,
    )));
    await tester.pumpAndSettle();

    expect(find.text('LINKS'), findsOneWidget);
    expect(find.text('SOCIAL PROFILES'), findsOneWidget);

    await tester.tap(find.byKey(
      const ValueKey('livingReportBlock:link:https://github.com/suhailps93'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsOneWidget);
    await _sendComposer(tester, 'that is not my github');

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'block');
    expect(correctCalls.single['block_ids'],
        ['link:https://github.com/suhailps93']);
  });

  testWidgets('a "Social profiles" block is tappable for edit',
      (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(
      correctCalls: correctCalls,
      includeLinksAndSocial: true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey(
      'livingReportBlock:social:https://instagram.com/suhail.p.sulaiman',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsOneWidget);
    await _sendComposer(tester, "that's not me");

    expect(correctCalls, hasLength(1));
    expect(correctCalls.single['scope'], 'block');
    expect(correctCalls.single['block_ids'],
        ['social:https://instagram.com/suhail.p.sulaiman']);
  });

  // --- scroll position across a dismiss (§ bug 1) ----------------------------

  double offsetOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .pixels;

  testWidgets(
      'dismissing the Edit-with-Ayma modal with no message sent leaves the '
      'report scrolled exactly where it was — no reload, no jump to top',
      (tester) async {
    final getCallLog = <int>[];
    await tester.pumpWidget(_host(_api(
      extraFacts: 40,
      getCallLog: getCallLog,
    )));
    await tester.pumpAndSettle();
    expect(getCallLog, hasLength(1)); // the one initial load

    // Scroll a deep block into view (rather than a fixed pixel drag) so the
    // target stays hit-testable regardless of exact row heights, then tap
    // it right where it landed.
    const target = ValueKey('livingReportBlock:fact:extra:35');
    await tester.scrollUntilVisible(find.byKey(target), 300);
    await tester.pumpAndSettle();
    final before = offsetOf(tester);
    expect(before, greaterThan(0)); // sanity: it actually scrolled

    await tester.tap(find.byKey(target));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsOneWidget);

    // Dismiss via the header's close button WITHOUT sending anything.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsNothing);
    expect(offsetOf(tester), before);
    // No-op dismiss must not have triggered another fetch.
    expect(getCallLog, hasLength(1));
  });

  testWidgets(
      'the report also keeps its scroll position after a real edit is sent '
      'and the modal is dismissed', (tester) async {
    final correctCalls = <Map<String, dynamic>>[];
    final getCallLog = <int>[];
    await tester.pumpWidget(_host(_api(
      extraFacts: 40,
      correctCalls: correctCalls,
      getCallLog: getCallLog,
    )));
    await tester.pumpAndSettle();

    const target = ValueKey('livingReportBlock:fact:extra:35');
    await tester.scrollUntilVisible(find.byKey(target), 300);
    await tester.pumpAndSettle();
    final before = offsetOf(tester);
    expect(before, greaterThan(0));

    await tester.tap(find.byKey(target));
    await tester.pumpAndSettle();
    await _sendComposer(tester, 'fix the year, it was 2021');
    expect(correctCalls, hasLength(1));
    // The exchange reloaded the report in place (stale-while-revalidate —
    // no spinner swap), which is exactly what should preserve scroll.
    expect(getCallLog.length, greaterThanOrEqualTo(2));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsNothing);
    expect(offsetOf(tester), before);
  });

  // --- quoted-context card for every tap tier (§ founder follow-up) ---------
  //
  // A block-scope tap already showed a quoted card (`_quoteTextFor`). Section
  // and report scope used to pass `quoteText: ''`, and the card only renders
  // when `quoteText` is non-empty — so it silently never appeared for those
  // two tiers even though `_AskAymaHeader` fully supports rendering it.

  testWidgets(
      'tapping a section heading shows a context card summarizing what is '
      'in scope, not a bare prompt', (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportSection:Summary')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.textContaining('SUMMARY'), findsWidgets); // the card's title
    // The card's body — item count + a preview of the section's own
    // content, not just a bare heading name.
    expect(
      find.textContaining('2 items — Jane works at Acme.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'tapping the report title shows a context card summarizing the whole '
      'report, not a bare prompt', (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportTitle')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.textContaining('sections'), findsOneWidget);
    expect(find.textContaining('items'), findsOneWidget);
  });

  group('story_public attribute privacy (§ founder: attributes are private '
      'by default)', () {
    // The owner's own review read: one already-public field, one still-
    // private field (each carrying its real `public` flag — only ever
    // present on the owner's own story_public read — see
    // `ReportBlock.public`'s doc), plus a narrative page sentence (always
    // already-public in story_public, unaffected by any of this).
    Map<String, dynamic> report() => {
          'title': 'Story',
          'sections': [
            {
              'heading': 'Attributes',
              'blocks': [
                {
                  'block_id': 'attr:eye_color',
                  'type': 'attribute',
                  'editable': true,
                  'label': 'Eyes',
                  'value': 'Brown',
                  'public': true,
                },
                {
                  'block_id': 'attr:build',
                  'type': 'attribute',
                  'editable': true,
                  'label': 'Build',
                  'value': 'Athletic',
                  'public': false,
                },
              ],
            },
            {
              'heading': 'Identity',
              'blocks': [
                {
                  'block_id': 'page:identity:sent:0',
                  'type': 'text',
                  'editable': true,
                  'text': 'A public sentence.',
                },
              ],
            },
          ],
          'meta': {
            'owner_uid': 'owner-uid',
            'viewer_can_edit': true,
            'created_at': null,
            'updated_at': null,
          },
        };

    ApiClient api({List<Map<String, dynamic>>? correctCalls}) {
      final mockHttp = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/report/story_public/owner-uid') {
          return http.Response(
            jsonEncode(report()),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/report/story_public/owner-uid/correct') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          correctCalls?.add(body);
          final ids = (body['block_ids'] as List).cast<String>();
          return http.Response(
            jsonEncode({
              'ok': true,
              'results': [
                for (final id in ids) {'block_id': id, 'ok': true, 'reply': 'done'},
              ],
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/chat/stream') {
          return http.Response('stream unavailable', 500);
        }
        if (request.url.path == '/chat') {
          return http.Response(
            jsonEncode({'reply': 'Sure.', 'usage_capped': false}),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 200);
      });
      return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    }

    Widget host(ApiClient api) => MaterialApp(
          home: Scaffold(
            body: LivingReportView(
              reportType: 'story_public',
              reportId: 'owner-uid',
              apiClient: api,
            ),
          ),
        );

    testWidgets('a private attribute block shows a "PRIVATE" tag',
        (tester) async {
      await tester.pumpWidget(host(api()));
      await tester.pumpAndSettle();

      expect(find.text('PRIVATE'), findsOneWidget);
    });

    testWidgets(
        'tapping a still-private attribute block offers "Make public", not '
        '"Make private"', (tester) async {
      await tester.pumpWidget(host(api()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('livingReportBlock:attr:build')));
      await tester.pumpAndSettle();

      expect(find.text('Make public'), findsOneWidget);
      expect(find.text('Make private'), findsNothing);
    });

    testWidgets(
        'tapping an already-public attribute block offers "Make private", '
        'not "Make public"', (tester) async {
      await tester.pumpWidget(host(api()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('livingReportBlock:attr:eye_color')));
      await tester.pumpAndSettle();

      expect(find.text('Make private'), findsOneWidget);
      expect(find.text('Make public'), findsNothing);
    });

    testWidgets(
        'a narrative page block keeps the old always-already-public '
        'assumption, unaffected by attribute privacy', (tester) async {
      await tester.pumpWidget(host(api()));
      await tester.pumpAndSettle();

      await tester.longPress(
          find.byKey(const ValueKey('livingReportBlock:page:identity:sent:0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat about these'));
      await tester.pumpAndSettle();

      expect(find.text('Make private'), findsOneWidget);
      expect(find.text('Make public'), findsNothing);
    });

    testWidgets(
        'tapping "Make public" on a private attribute block sends the exact '
        'quick-action phrase for just that block', (tester) async {
      final correctCalls = <Map<String, dynamic>>[];
      await tester.pumpWidget(host(api(correctCalls: correctCalls)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('livingReportBlock:attr:build')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make public'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(correctCalls, hasLength(1));
      expect(correctCalls.single['message'], 'Make public');
      expect(correctCalls.single['block_ids'], ['attr:build']);
    });
  });
}
