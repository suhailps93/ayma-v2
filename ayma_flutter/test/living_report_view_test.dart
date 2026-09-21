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
// - a text-block sentence only responds to long-press, never a bare tap.
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/living_report_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _report({bool viewerCanEdit = true}) => {
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
}) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/report/deep_dive/rid1') {
      return http.Response(
        jsonEncode(_report(viewerCanEdit: viewerCanEdit)),
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

void main() {
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
      'a bare short tap on a text-block sentence does nothing (fragile-tap '
      'guard) — only long-press resolves to anything', (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('livingReportBlock:summary:sent:0')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsNothing);
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
