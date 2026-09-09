import 'dart:convert';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:ayma_flutter/services/api_client.dart';

void main() {
  test('chat() sends the message with a Bearer token and returns reply',
      () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;

    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'reply': 'hi back'}), 200);
    });

    final client = ApiClient(httpClient: mockHttp, auth: auth);
    final result = await client.chat('hello', sessionId: 's-unit-000001');

    expect(result.reply, 'hi back');
    expect(result.capped, isFalse);
    expect(result.toolsUsed, isEmpty);
    expect(captured.url.path, '/chat');
    expect(captured.headers['Authorization'], startsWith('Bearer '));
    expect(jsonDecode(captured.body), {
      'message': 'hello',
      'session_id': 's-unit-000001',
      'viewing_profile_uid': '',
      'recent_turns': [],
      'image_path': '',
      'story_page_id': '',
      'story_passage': '',
      'profile_edit': false,
    });
  });

  test('chat() parses the tools Ayma used', () async {
    final mockHttp = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'reply': 'here you go',
          'tools_used': ['Searched the web', 'Updated your profile'],
        }),
        200,
      );
    });
    final client = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );
    final result = await client.chat('look it up', sessionId: 's-unit-000009');
    expect(result.toolsUsed, ['Searched the web', 'Updated your profile']);
  });

  test('chatStream() yields status events then a reply', () async {
    final sse = 'data: {"type":"status","label":"Thinking…"}\n\n'
        'data: {"type":"status","label":"Searching the web…"}\n\n'
        'data: {"type":"reply","text":"found it","tools_used":["Searched the web"]}\n\n';
    final client = ApiClient(
      httpClient: MockClient((req) async {
        expect(req.url.path, '/chat/stream');
        return http.Response.bytes(utf8.encode(sse), 200);
      }),
      auth: MockFirebaseAuth(signedIn: true),
    );

    final events = await client.chatStream('what won?').toList();
    expect(events.whereType<ChatStatus>().map((e) => e.label),
        ['Thinking…', 'Searching the web…']);
    final reply = events.whereType<ChatReplyEvent>().single.result;
    expect(reply.reply, 'found it');
    expect(reply.toolsUsed, ['Searched the web']);
  });

  test('chatStream() throws ApiException on a non-200 so the caller can fall '
      'back', () async {
    final client = ApiClient(
      httpClient: MockClient((req) async => http.Response('nope', 503)),
      auth: MockFirebaseAuth(signedIn: true),
    );
    expect(client.chatStream('hi').toList(), throwsA(isA<ApiException>()));
  });

  test('chat() forwards the recent-turns window', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'reply': 'ok'}), 200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    await client.chat('now in text', sessionId: 's-unit-000002', recentTurns: [
      {'role': 'user', 'text': 'said out loud'},
      {'role': 'ayma', 'text': 'mm-hm'},
    ]);

    expect(jsonDecode(captured.body), {
      'message': 'now in text',
      'session_id': 's-unit-000002',
      'viewing_profile_uid': '',
      'recent_turns': [
        {'role': 'user', 'text': 'said out loud'},
        {'role': 'ayma', 'text': 'mm-hm'},
      ],
      'image_path': '',
      'story_page_id': '',
      'story_passage': '',
      'profile_edit': false,
    });
  });

  test('bootstrap() posts the recent-turns window and parses credentials',
      () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'session_mode': 'marketing',
          'uid': 'u1',
          'livekit': {'token': 't', 'url': 'wss://x', 'room': 'ayma-u1'},
        }),
        200,
      );
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final result = await client.bootstrap(sessionId: 's-unit-000003', recentTurns: [
      {'role': 'user', 'text': 'hi'},
    ]);

    expect(captured.url.path, '/bootstrap');
    expect(jsonDecode(captured.body), {
      'session_id': 's-unit-000003',
      'recent_turns': [
        {'role': 'user', 'text': 'hi'},
      ],
    });
    expect(result.livekitToken, 't');
    expect(result.room, 'ayma-u1');
  });

  test('chat() throws ApiException on non-200', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response('nope', 500));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    expect(() => client.chat('x'), throwsA(isA<ApiException>()));
  });

  test('bootstrap() surfaces recovery_required', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response(
        jsonEncode({'recovery_required': true, 'uid': 'u1'}), 200));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final result = await client.bootstrap(sessionId: '');
    expect(result.recoveryRequired, isTrue);
  });

  test('bootstrap() keeps session_mode when usage_capped', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response(
        jsonEncode({
          'usage_capped': true,
          'uid': 'u1',
          'session_mode': 'active',
        }),
        200));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final result = await client.bootstrap(sessionId: '');
    // Out of credits must not strand a signed-in user in marketing mode.
    expect(result.usageCapped, isTrue);
    expect(result.sessionMode, 'active');
    expect(result.livekitToken, isEmpty);
  });

  test('deleteAccount / recoverAccount POST and check status', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final paths = <String>[];
    final mockHttp = MockClient((req) async {
      paths.add(req.url.path);
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    await client.deleteAccount();
    await client.recoverAccount();
    expect(paths, ['/account/delete', '/account/recover']);

    final failHttp = MockClient((_) async => http.Response('no', 502));
    expect(
      () => ApiClient(httpClient: failHttp, auth: auth).deleteAccount(),
      throwsA(isA<ApiException>()),
    );
  });

  test('chat() surfaces the turn-cap signal', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response(
        jsonEncode({
          'reply': 'tap get started',
          'capped': true,
          'fallback_form': false,
        }),
        200));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final result = await client.chat('still here?');
    expect(result.reply, 'tap get started');
    expect(result.capped, isTrue);
    expect(result.fallbackForm, isFalse);
  });

  test('registerMedia() posts the storage path and context', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'ok': true, 'media_id': 'm1'}), 200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    await client.registerMedia('uploads/u1/profile_1.jpg', context: 'profile');

    expect(captured.url.path, '/media');
    expect(jsonDecode(captured.body), {
      'storage_path': 'uploads/u1/profile_1.jpg',
      'context': 'profile',
    });
  });

  test('registerMedia() throws on non-200', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response('boom', 502));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    expect(
      () => client.registerMedia('uploads/u1/x.jpg'),
      throwsA(isA<ApiException>()),
    );
  });

  test('instagramAuthUrl() returns the url from the response', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'url': 'https://api.instagram.com/oauth/authorize?x=1'}),
          200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final url = await client.instagramAuthUrl();
    expect(captured.method, 'GET');
    expect(captured.url.path, '/instagram/auth-url');
    expect(url, contains('oauth/authorize'));
  });

  test('instagramConnect() posts the code and returns imported count',
      () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'ok': true, 'imported': 7}), 200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final n = await client.instagramConnect('the-code');
    expect(jsonDecode(captured.body), {'code': 'the-code'});
    expect(n, 7);
  });

  test('submitFeedback() POSTs /feedback with the thumbed-down message',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true, 'id': 'f-1'}), 200);
      }),
    );

    await client.submitFeedback(
      category: 'thumbs_down',
      quote: 'That felt canned.',
      sessionId: 's-1',
    );
    expect(captured.url.path, '/feedback');
    expect(jsonDecode(captured.body), {
      'category': 'thumbs_down',
      'quote': 'That felt canned.',
      'note': '',
      'session_id': 's-1',
    });
  });

  test('submitProductFeedback() POSTs /product-feedback with paths', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true, 'id': 'p-1'}), 200);
      }),
    );

    await client.submitProductFeedback(
      kind: 'bug',
      text: 'orb flickers',
      imagePaths: const ['uploads/me/feedback_1.png'],
    );
    expect(captured.url.path, '/product-feedback');
    expect(jsonDecode(captured.body), {
      'kind': 'bug',
      'text': 'orb flickers',
      'image_paths': ['uploads/me/feedback_1.png'],
      'app_version': '',
    });
  });

  test('usage() parses the derived credit balance and per-action costs',
      () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        expect(req.url.path, '/usage');
        return http.Response(
          jsonEncode({
            'total': 12000,
            'cap': 100000,
            'remaining': 88000,
            'features': {'chat': 12000},
            'credits': {'grant': 100, 'added': 50, 'used': 12,
                        'remaining': 138},
            'tokens_per_credit': 1000,
            'costs': {'match_score': 12},
          }),
          200,
        );
      }),
    );

    final u = await client.usage();
    expect(u.creditGrant, 100);
    expect(u.creditsAdded, 50);
    expect(u.creditsUsed, 12);
    expect(u.creditsRemaining, 138);
    expect(u.creditsTotal, 150);
    expect(u.tokensPerCredit, 1000);
    expect(u.costMatchScore, 12);
    expect(u.creditsForFeature(12000), 12);
    expect(u.creditsForFeature(1), 1); // rounds up a partial credit
  });

  test('topUpCredits() POSTs /credits/topup and parses the new balance',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'total': 0, 'cap': 100000, 'remaining': 100000, 'features': {},
            'credits': {'grant': 100, 'added': 100, 'used': 0,
                        'remaining': 200},
            'tokens_per_credit': 1000, 'costs': {'match_score': 12},
          }),
          200,
        );
      }),
    );

    final u = await client.topUpCredits();
    expect(captured.method, 'POST');
    expect(captured.url.path, '/credits/topup');
    expect(u.creditsAdded, 100);
    expect(u.creditsRemaining, 200);
  });

  test('checkCompatibility() posts the other uid and parses the score',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'ok': true, 'match_id': 'a__b', 'score': 0.73}),
          200,
        );
      }),
    );

    final res = await client.checkCompatibility('b');
    expect(captured.url.path, '/check-compatibility');
    expect(jsonDecode(captured.body), {'other_uid': 'b', 'force': false});
    expect(res.ok, isTrue);
    expect(res.usageCapped, isFalse);
    expect(res.score, 0.73);
    expect(res.matchId, 'a__b');
  });

  test('skillReport() GETs the stored report and returns dict + created_at',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'report': {'usable': true, 'overall_score': 7.1},
            'created_at': '2026-09-05T12:00:00Z',
          }),
          200,
        );
      }),
    );

    final r = await client.skillReport('face', 'abc123');
    expect(captured.method, 'GET');
    expect(captured.url.path, '/skills/report/face/abc123');
    expect(r.report['overall_score'], 7.1);
    expect(r.createdAt, '2026-09-05T12:00:00Z');
    expect(FaceReport.fromMap(r.report).overallScore, 7.1);
  });

  test('skillReport() throws ApiException on non-200', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response('gone', 404)),
    );
    expect(() => client.skillReport('body', 'nope'),
        throwsA(isA<ApiException>()));
  });

  test('skillReports() lists the stored reports for a skill', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'reports': [
              {
                'id': 'r1',
                'overall_score': 7.2,
                'verdict': 'Above average',
                'created_at': '2026-09-05T12:00:00Z',
                'image_path': 'uploads/u1/a.jpg',
              },
              {'id': '', 'overall_score': 0, 'verdict': ''},
            ],
          }),
          200,
        );
      }),
    );

    final rows = await client.skillReports('face');
    expect(captured.method, 'GET');
    expect(captured.url.path, '/skills/reports/face');
    expect(rows, hasLength(1)); // the id-less row is dropped
    expect(rows.first.id, 'r1');
    expect(rows.first.overallScore, 7.2);
    expect(rows.first.verdict, 'Above average');
    expect(rows.first.imagePath, 'uploads/u1/a.jpg');
  });

  test('promoteWikiPage() POSTs /wiki/promote with the page type', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );

    await client.promoteWikiPage('face_analysis');
    expect(captured.method, 'POST');
    expect(captured.url.path, '/wiki/promote');
    expect(jsonDecode(captured.body), {'page_type': 'face_analysis'});
  });

  test('checkCompatibility() surfaces the usage-capped signal', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async => http.Response(
          jsonEncode({'ok': false, 'usage_capped': true}), 200)),
    );

    final res = await client.checkCompatibility('b');
    expect(res.ok, isFalse);
    expect(res.usageCapped, isTrue);
    expect(res.score, isNull);
  });

  // --- Your Story editor -------------------------------------------------

  test('storyGet() reads the whole document', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'sections': [
              {
                'page_id': 'career',
                'page_type': 'career',
                'title': 'Career',
                'body': 'Leads a team.',
                'visibility': 'public',
                'is_skill': false,
                'has_private_spans': true,
                'ai_updated_since_user': true,
              },
            ],
          }),
          200,
        );
      }),
    );

    final data = await client.storyGet();
    expect(captured.method, 'GET');
    expect(captured.url.path, '/story');
    expect(data.sections.single.title, 'Career');
    expect(data.sections.single.hasPrivateSpans, isTrue);
  });

  test('storySaveSection() PUTs the body and returns the version id', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'head_version_id': 'v10'}), 200);
      }),
    );
    final head = await client.storySaveSection(
        pageId: 'career', body: 'New body', visibility: 'private');
    expect(captured.method, 'PUT');
    expect(captured.url.path, '/story/section');
    expect(jsonDecode(captured.body),
        {'page_id': 'career', 'body': 'New body', 'visibility': 'private'});
    expect(head, 'v10');
  });

  test('storySetVisibility() POSTs the section visibility', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'head_version_id': 'v11'}), 200);
      }),
    );
    await client.storySetVisibility(pageId: 'career', visibility: 'private');
    expect(captured.url.path, '/story/section/visibility');
    expect(jsonDecode(captured.body),
        {'page_id': 'career', 'visibility': 'private'});
  });

  test('storyEdit() posts the thread and parses a reply + revised body',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'reply': 'How about this?',
            'revised_body': 'Tighter version.',
            'action': 'chat',
          }),
          200,
        );
      }),
    );
    final r = await client.storyEdit(
      pageId: 'career',
      selection: 'some words',
      messages: [
        {'role': 'user', 'text': 'shorten it'},
      ],
    );
    expect(captured.url.path, '/story/edit');
    expect(jsonDecode(captured.body)['messages'], [
      {'role': 'user', 'text': 'shorten it'},
    ]);
    expect(r.reply, 'How about this?');
    expect(r.revisedBody, 'Tighter version.');
    expect(r.action, 'chat');
  });

  test('storyEdit() parses a move action and the usage-capped signal',
      () async {
    final move = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async => http.Response(
          jsonEncode({'reply': 'ok', 'action': 'move',
                      'target_visibility': 'public'}), 200)),
    );
    final r = await move.storyEdit(pageId: 'p', selection: '', messages: []);
    expect(r.action, 'move');
    expect(r.targetVisibility, 'public');

    final capped = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async =>
          http.Response(jsonEncode({'usage_capped': true}), 200)),
    );
    final r2 =
        await capped.storyEdit(pageId: 'p', selection: '', messages: []);
    expect(r2.usageCapped, isTrue);
  });

  test('storyRemoveSection() POSTs the page id', () async {
    final paths = <String>[];
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        paths.add(req.url.path);
        return http.Response(jsonEncode({'deleted': true}), 200);
      }),
    );
    await client.storyRemoveSection('p');
    expect(paths, ['/story/section/remove']);
  });

  test('storySectionVersions() lists one section\'s history newest-first',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode([
            {'id': 'v2', 'author': 'ayma', 'note': 'learned',
             'visibility': 'public', 'created_at_ms': 1000},
            {'id': 'v1', 'author': 'user', 'note': '',
             'visibility': 'public', 'created_at_ms': 500},
          ]),
          200,
        );
      }),
    );
    final rows = await client.storySectionVersions('career');
    expect(captured.url.path, '/story/section/career/versions');
    expect(rows.map((v) => v.id), ['v2', 'v1']);
    expect(rows.first.author, 'ayma');
    expect(rows.first.visibility, 'public');
  });

  test('storySectionVersion() parses one stored version', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        expect(req.url.path, '/story/section/career/versions/v1');
        return http.Response(
          jsonEncode({
            'id': 'v1',
            'body': 'snapshot body',
            'visibility': 'private',
            'author': 'user',
            'note': 'reverted to v0',
            'created_at_ms': 42,
          }),
          200,
        );
      }),
    );
    final v = await client.storySectionVersion('career', 'v1');
    expect(v.body, 'snapshot body');
    expect(v.visibility, 'private');
    expect(v.note, 'reverted to v0');
  });

  test('storySectionRevert() POSTs page + version id', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'head_version_id': 'v5'}), 200);
      }),
    );
    final head =
        await client.storySectionRevert(pageId: 'career', versionId: 'v2');
    expect(captured.url.path, '/story/section/revert');
    expect(jsonDecode(captured.body),
        {'page_id': 'career', 'version_id': 'v2'});
    expect(head, 'v5');
  });
}
