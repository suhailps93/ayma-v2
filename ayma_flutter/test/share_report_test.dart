// Shareable reports: ReportShare, ShareService (card download, Instagram
// fallback, DM send), the share sheet's "Share to Ayma" hand-off, and the
// read-only SharedReportScreen deep-link view.
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
import 'package:flutter/services.dart';
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
  _FakeDm({this.failUpload = false})
      : super(auth: MockFirebaseAuth(signedIn: true));
  final bool failUpload;
  final List<String> texts = [];
  final List<String> captions = [];

  @override
  Future<DmAttachment> uploadAttachment(File file,
      {required String threadId}) async {
    if (failUpload) throw Exception('upload failed');
    return const DmAttachment(
        storagePath: 'p',
        downloadUrl: 'u',
        contentType: 'image/png',
        sizeBytes: 4,
        name: 'n.png');
  }

  @override
  Future<void> sendAttachment(String threadId,
      {required String type,
      required DmAttachment attachment,
      String caption = ''}) async {
    captions.add(caption);
  }

  @override
  Future<void> sendText(String threadId, String text) async =>
      texts.add(text);
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
        tempDir: tmp,
        facebookAppId: 'fb');
    final f = await svc.downloadCard(_share, story: true);
    expect(seen.last.url.queryParameters['format'], 'story');
    expect(f.readAsBytesSync(), [137, 80, 78, 71]);
  });

  test('instagram story: false without an app id or on platform failure',
      () async {
    final seen = <http.Request>[];
    final noId = ShareService(
        httpClient: _backend(seen), tempDir: tmp, facebookAppId: '');
    expect(await noId.shareToInstagramStory(_share), isFalse);
    expect(seen, isEmpty);

    const channel = MethodChannel('ayma/share');
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'STORY_FAILED');
    });
    final svc = ShareService(
        httpClient: _backend(seen),
        channel: channel,
        tempDir: tmp,
        facebookAppId: 'fb');
    expect(await svc.shareToInstagramStory(_share), isFalse);
    expect(calls.single.arguments['appId'], 'fb');
    expect(calls.single.arguments['contentUrl'], _share.url);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    expect(await svc.shareToInstagramStory(_share), isTrue);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sendToThread sends the card with caption, else falls back to text',
      () async {
    final seen = <http.Request>[];
    final svc = ShareService(httpClient: _backend(seen), tempDir: tmp);
    final ok = _FakeDm();
    await svc.sendToThread(ok, 'a__b', _share);
    expect(ok.captions, [_share.message]);
    expect(ok.texts, isEmpty);

    final bad = _FakeDm(failUpload: true);
    await svc.sendToThread(bad, 'a__b', _share);
    expect(bad.texts, [_share.message]);
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
                    reportType: 'appearance',
                    reportId: 'u1',
                    apiClient: _api(_backend(seen)),
                  ),
                ]),
              )),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    for (final label in [
      'Instagram Story',
      'Share to Ayma',
      'Send to a user',
      'More…'
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Share to Ayma'));
    await tester.pumpAndSettle();

    final body = jsonDecode(seen.firstWhere((r) => r.url.path == '/share').body);
    expect(body, {'report_type': 'appearance', 'report_id': 'u1'});
    final k = ChatInbox.instance.take();
    expect(k?.kind, 'draft_text');
    expect(k?.draftBody, contains(_share.url));
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
