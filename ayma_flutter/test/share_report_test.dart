// Shareable reports on the unified share kit: ReportShare, ShareService
// (snapshot + card download), the kit sheet's two options ("Send to Ayma"
// / "Send externally") for report targets, the exact-record rule for the
// external payload, and the read-only SharedReportScreen deep-link view.
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/models/report_share.dart';
import 'package:ayma_flutter/screens/shared_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/share_kit.dart';
import 'package:ayma_flutter/services/share_service.dart';
import 'package:ayma_flutter/widgets/share_report_sheet.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:share_plus/share_plus.dart';

const _token = 'tok-abc123';

final _share = ReportShare.fromMap({
  'token': _token,
  'url': 'https://justabot.info/s/$_token',
  'card_url': 'https://justabot.info/s/$_token/card.png',
  'title': 'Web research on Dillu',
  'summary': 'Score: 7',
});

MockClient _backend(List<http.Request> seen) => MockClient((req) async {
      seen.add(req);
      if (req.url.path == '/share') {
        return http.Response(
            jsonEncode({
              'token': _token,
              'url': _share.url,
              'card_url': _share.cardUrl,
              'title': 'Web research on Dillu',
              'summary': 'Score: 7',
            }),
            200);
      }
      if (req.url.path.endsWith('/data')) {
        return http.Response(
            jsonEncode({
              'title': 'Shared thing',
              'sections': [
                {
                  'heading': 'Overview',
                  'blocks': [
                    {
                      'block_id': 't',
                      'type': 'text',
                      'editable': false,
                      'text': 'Hello from a snapshot.',
                    },
                  ],
                },
              ],
              'meta': {'owner_uid': '', 'viewer_can_edit': false},
            }),
            200);
      }
      if (req.url.path.endsWith('card.png')) {
        return http.Response.bytes([137, 80, 78, 71], 200);
      }
      return http.Response('{}', 404);
    });

ApiClient _api(MockClient c) =>
    ApiClient(httpClient: c, auth: MockFirebaseAuth(signedIn: true));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('share_test'));
  tearDown(() => tmp.deleteSync(recursive: true));
  tearDown(() => ChatInbox.instance.take());

  test('ReportShare builds the story card url and a link message', () {
    expect(_share.storyCardUrl, '${_share.cardUrl}?format=story');
    expect(_share.message, 'Web research on Dillu — Score: 7\n${_share.url}');
  });

  test('downloadCard fetches the story format when asked', () async {
    final seen = <http.Request>[];
    final svc = ShareService(
        api: _api(_backend(seen)),
        httpClient: _backend(seen),
        tempDir: tmp);
    final f = await svc.downloadCard(_share, story: true);
    expect(seen.last.url.queryParameters['format'], 'story');
    expect(f.readAsBytesSync(), [137, 80, 78, 71]);
  });

  test('downloadCard rejects a 200 HTML body (host not routed to backend)',
      () async {
    final svc = ShareService(
      httpClient: MockClient((_) async => http.Response(
          '<!doctype html><title>Ayma</title>', 200,
          headers: {'content-type': 'text/html'})),
      tempDir: Directory.systemTemp,
    );
    expect(() => svc.downloadCard(_share), throwsA(isA<ApiException>()));
  });

  testWidgets('the report share button opens the kit sheet with the two '
      'options, and Send to Ayma hands the report to the chat', (tester) async {
    final seen = <http.Request>[];
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
                appBar: AppBar(actions: [
                  ShareReportButton(
                    reportType: 'deep_dive',
                    reportId: 'dive-opened',
                    subjectUid: 'u2',
                    subjectName: 'Dillu',
                    apiClient: _api(_backend(seen)),
                  ),
                ]),
              )),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    // The unified sheet: exactly the founder's two labels.
    expect(find.text('Send to Ayma'), findsOneWidget);
    expect(find.text('Send externally'), findsOneWidget);
    expect(find.text('Share to Ayma'), findsNothing);
    expect(find.text('Send to a user'), findsNothing);
    await tester.tap(find.text('Send to Ayma'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.take();
    expect(k?.kind, 'draft_about');
    expect(k?.shareKind, 'deep_dive');
    expect(k?.refId, 'dive-opened');
    expect(k?.targetUid, 'u2');
    // Sending to Ayma needs no public snapshot at all.
    expect(seen.where((r) => r.url.path == '/share'), isEmpty);
  });

  test('Send externally composes the share from the exact opened record',
      () async {
    final seen = <http.Request>[];
    final backend = _backend(seen);
    ShareParams? captured;
    final kit = AymaShare(
      api: _api(backend),
      httpClient: backend,
      systemShare: (p) async => captured = p,
    );
    await kit.shareExternally(
      _FakeContext(),
      ShareTargets.webResearch(
        reportId: 'dive-opened',
        subjectUid: 'u2',
        subjectName: 'Dillu',
      ),
    );
    // The snapshot was created for THIS report id — the one the user
    // opened — never re-resolved by pair/person to a different record.
    final create =
        seen.firstWhere((r) => r.url.path == '/share' && r.method == 'POST');
    expect(jsonDecode(create.body),
        {'report_type': 'deep_dive', 'report_id': 'dive-opened'});
    // And the composed share is that snapshot's own title/summary/link.
    expect(captured?.text, 'Web research on Dillu — Score: 7\n${_share.url}');
    expect(captured?.subject, 'Web research on Dillu');
  });

  testWidgets('SharedReportScreen renders the public snapshot',
      (tester) async {
    final seen = <http.Request>[];
    await tester.pumpWidget(MaterialApp(
      home: SharedReportScreen(token: _token, apiClient: _api(_backend(seen))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Hello from a snapshot.'), findsOneWidget);
    expect(seen.single.url.path, '/s/$_token/data');
    expect(seen.single.headers.containsKey('authorization'), isFalse);
  });
}

/// A bare context for the non-widget external path (the fake system
/// share ignores it).
class _FakeContext extends Fake implements BuildContext {}
