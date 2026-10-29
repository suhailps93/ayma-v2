// Shareable reports: ReportShare, ShareService (card download, native share,
// DM send), the share sheet's "Share to Ayma" hand-off, and the read-only
// SharedReportScreen deep-link view.
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/models/report_share.dart';
import 'package:ayma_flutter/screens/shared_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/share_service.dart';
import 'package:ayma_flutter/widgets/share_report_sheet.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

final _share = ReportShare.fromMap({
  'token': _token,
  'url': 'https://justabot.info/s/$_token',
  'card_url': 'https://justabot.info/s/$_token/card.png',
  'title': 'Appearance',
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
              'title': 'Appearance',
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

class _FakeDm extends DmService {
  _FakeDm() : super(auth: MockFirebaseAuth(signedIn: true));
  final List<(String, String)> reportShares = [];

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<void> sendReportShare(String threadId, String shareToken) async =>
      reportShares.add((threadId, shareToken));
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('share_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('ReportShare builds the story card url and a link message', () {
    expect(_share.storyCardUrl, '${_share.cardUrl}?format=story');
    expect(_share.message, 'Appearance — Score: 7\n${_share.url}');
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

  test('sendToThread sends an in-app report card, not the external link',
      () async {
    final svc = ShareService(httpClient: _backend([]), tempDir: tmp);
    final dm = _FakeDm();
    await svc.sendToThread(dm, 'a__b', _share);
    expect(dm.reportShares, [('a__b', _token)]);
  });

  testWidgets('"Share to Ayma" drafts the link into the Ayma chat',
      (tester) async {
    final seen = <http.Request>[];
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
                appBar: AppBar(actions: [
                  ShareReportButton(
                    reportType: 'deep_dive',
                    reportId: 'u1',
                    apiClient: _api(_backend(seen)),
                  ),
                ]),
              )),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    for (final label in ['Share', 'Share to Ayma', 'Send to a user']) {
      expect(find.text(label), findsOneWidget);
    }
    // The per-app Instagram Story button is gone — the native "Share" covers
    // Instagram (and everything else) through the OS share sheet.
    expect(find.text('Instagram Story'), findsNothing);
    await tester.tap(find.text('Share to Ayma'));
    await tester.pumpAndSettle();

    final body = jsonDecode(seen.firstWhere((r) => r.url.path == '/share').body);
    expect(body, {'report_type': 'deep_dive', 'report_id': 'u1'});
    final k = ChatInbox.instance.take();
    expect(k?.kind, 'draft_text');
    expect(k?.draftBody, contains('Appearance'));
    expect(k?.draftBody, isNot(contains('justabot.info')));
  });

  testWidgets('SharedReportScreen renders the public snapshot',
      (tester) async {
    final seen = <http.Request>[];
    await tester.pumpWidget(MaterialApp(
      home: SharedReportScreen(
          token: _token, apiClient: _api(_backend(seen))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Hello from a snapshot.'), findsOneWidget);
    expect(seen.single.url.path, '/s/$_token/data');
    expect(seen.single.headers.containsKey('authorization'), isFalse);
  });
}
