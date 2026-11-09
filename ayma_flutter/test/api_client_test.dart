import 'dart:async';
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
      'client_msg_id': '',
      'viewing_profile_uid': '',
      'recent_turns': [],
      'image_path': '',
      'story_page_id': '',
      'story_passage': '',
      'story_timeline_entry_id': '',
      'deep_dive_report_id': '',
      'deep_dive_target': '',
      'appearance_finding_id': '',
      'match_report_id': '',
      'shared_kind': '',
      'shared_ref_id': '',
      'shared_subject_uid': '',
      'shared_subject_name': '',
      'shared_ref_version': '',
      'profile_edit': false,
      'photo_url': '',
      'photo_source': '',
      'screen': '',
      'screen_subject_uid': '',
      'screen_subject_name': '',
      'screen_note': '',
      'screen_route': '',
      'screen_detail': '',
      'screen_visible': '',
      'screen_previous_route': '',
      'screen_previous_label': '',
      'tour_continuation': false,
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

  test('chatStream() times out a stalled stream as a connection-class '
      'ApiException instead of hanging', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    final client = ApiClient(
      httpClient: MockClient.streaming((req, _) async =>
          http.StreamedResponse(controller.stream, 200)),
      auth: MockFirebaseAuth(signedIn: true),
      chatStreamIdleTimeout: const Duration(milliseconds: 50),
    );
    controller.add(utf8.encode('data: {"type":"status","label":"Thinking…"}\n\n'));

    final events = <ChatEvent>[];
    await expectLater(
      () async {
        await for (final e in client.chatStream('hi')) {
          events.add(e);
        }
      }(),
      throwsA(isA<ApiException>().having(
        (e) => e.message, 'message', startsWith('Network error'))),
    );
    expect(events.whereType<ChatStatus>(), hasLength(1));
  });

  test('chatStream() ignores keepalive comment frames', () async {
    final sse = ': keepalive\n\n'
        'data: {"type":"reply","text":"hi","tools_used":[]}\n\n';
    final client = ApiClient(
      httpClient:
          MockClient((req) async => http.Response.bytes(utf8.encode(sse), 200)),
      auth: MockFirebaseAuth(signedIn: true),
    );
    final events = await client.chatStream('hey').toList();
    expect(events.whereType<ChatReplyEvent>().single.result.reply, 'hi');
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
      'client_msg_id': '',
      'viewing_profile_uid': '',
      'recent_turns': [
        {'role': 'user', 'text': 'said out loud'},
        {'role': 'ayma', 'text': 'mm-hm'},
      ],
      'image_path': '',
      'story_page_id': '',
      'story_passage': '',
      'story_timeline_entry_id': '',
      'deep_dive_report_id': '',
      'deep_dive_target': '',
      'appearance_finding_id': '',
      'match_report_id': '',
      'shared_kind': '',
      'shared_ref_id': '',
      'shared_subject_uid': '',
      'shared_subject_name': '',
      'shared_ref_version': '',
      'profile_edit': false,
      'photo_url': '',
      'photo_source': '',
      'screen': '',
      'screen_subject_uid': '',
      'screen_subject_name': '',
      'screen_note': '',
      'screen_route': '',
      'screen_detail': '',
      'screen_visible': '',
      'screen_previous_route': '',
      'screen_previous_label': '',
      'tour_continuation': false,
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

  test(
      'bootstrap() gives a practice return the long budget, not the '
      'interactive one (note 134)', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    // The server's debrief seeding answers in 300 ms here; the client's
    // interactive budget is squeezed to 50 ms and its long budget to 2 s
    // so the two budgets are distinguishable in test time.
    final mockHttp = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return http.Response(
        jsonEncode({
          'session_mode': 'active',
          'uid': 'u1',
          'livekit': {'token': 't', 'url': 'wss://x', 'room': 'ayma-u1'},
        }),
        200,
      );
    });
    final client = ApiClient(
      httpClient: mockHttp,
      auth: auth,
      interactiveTimeout: const Duration(milliseconds: 50),
      longTimeout: const Duration(seconds: 2),
    );

    // A plain bootstrap stays on the interactive budget: a 300 ms answer
    // is too slow, and the call aborts with the 408 request timeout.
    await expectLater(
      client.bootstrap(sessionId: 's-unit-000004'),
      throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 408)),
    );

    // The SAME answer speed succeeds for a practice return: seeding the
    // debrief (reading the finished practice session, building the
    // greeting) legitimately takes longer than an interactive call. On
    // build 2334 this call died at the 8 s interactive budget, twice,
    // while the plain bootstrap beside it succeeded (note 134).
    final result = await client.bootstrap(
      sessionId: 's-unit-000004',
      practiceReturnSessionId: 'practice_1',
    );
    expect(result.livekitToken, 't');
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
      'caption_context': '',
    });
  });

  test('registerMedia() forwards the accompanying caption text', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'ok': true, 'media_id': 'm1'}), 200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    await client.registerMedia(
      'uploads/u1/chat_1.jpg',
      context: 'chat',
      captionContext: 'feeling great today',
    );

    expect(jsonDecode(captured.body), {
      'storage_path': 'uploads/u1/chat_1.jpg',
      'context': 'chat',
      'caption_context': 'feeling great today',
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

  test('completeOnboarding() posts to /onboarding/complete', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'triggered': true, 'web_search': true, 'photo_scan': true}),
          200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    await client.completeOnboarding();

    expect(captured.method, 'POST');
    expect(captured.url.path, '/onboarding/complete');
  });

  test('addPhotosBatch() posts every media id and parses added/failed',
      () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({
            'ok': true,
            'photos': [
              {'media_id': 'm1', 'order': 0},
            ],
            'added': ['m1', 'm2'],
            'failed': ['m3'],
          }),
          200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    final result = await client.addPhotosBatch(['m1', 'm2', 'm3']);

    expect(captured.url.path, '/media/photos/batch');
    expect(jsonDecode(captured.body), {'media_ids': ['m1', 'm2', 'm3']});
    expect(result.added, ['m1', 'm2']);
    expect(result.failed, ['m3']);
    expect(result.photos, [{'media_id': 'm1', 'order': 0}]);
  });

  test('addPhotosBatch() throws on non-200', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response('boom', 502));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    expect(
      () => client.addPhotosBatch(['m1']),
      throwsA(isA<ApiException>()),
    );
  });

  test('rescanWebSearchPhotos() posts the given storage paths', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'queued': true}), 200);
    });
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    await client.rescanWebSearchPhotos(storagePaths: ['uploads/u1/a.jpg']);

    expect(captured.url.path, '/web-search/photos/rescan');
    expect(jsonDecode(captured.body), {
      'storage_paths': ['uploads/u1/a.jpg'],
    });
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

  test('submitFeedbackCard() POSTs /feedback/submit with the full payload',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true, 'id': 'p-1'}), 200);
      }),
    );

    await client.submitFeedbackCard(
      kind: 'bug',
      title: 'Orb flickers',
      body: 'orb flickers on messages',
      screenshotPaths: const ['uploads/me/feedback_1.png'],
      screen: 'messages',
      appVersion: '1.30.0',
      platform: 'android',
      source: 'chat_card',
    );
    expect(captured.url.path, '/feedback/submit');
    expect(jsonDecode(captured.body), {
      'kind': 'bug',
      'title': 'Orb flickers',
      'body': 'orb flickers on messages',
      'screenshot_paths': ['uploads/me/feedback_1.png'],
      'screen': 'messages',
      'app_version': '1.30.0',
      'platform': 'android',
      'source': 'chat_card',
    });
  });

  test('adminListFeedback() GETs /admin/feedback and parses rows', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        expect(req.url.path, '/admin/feedback');
        return http.Response(
          jsonEncode({
            'feedback': [
              {
                'id': 'f1',
                'uid': 'u1',
                'source': 'settings_form',
                'kind': 'feature',
                'title': 'Dark map',
                'body': 'a dark explore map',
                'screenshot_paths': ['uploads/u1/feedback_1.png'],
                'screen': 'settings/feedback',
                'app_version': '1.30.0',
                'platform': 'ios',
                'status': 'triaged',
                'created_at': '2026-10-20T10:00:00Z',
              },
            ],
          }),
          200,
        );
      }),
    );

    final rows = await client.adminListFeedback();
    expect(rows, hasLength(1));
    expect(rows.single.title, 'Dark map');
    expect(rows.single.source, 'settings_form');
    expect(rows.single.status, 'triaged');
    expect(rows.single.screenshotPaths, ['uploads/u1/feedback_1.png']);
  });

  test('adminSetFeedbackStatus() POSTs the new status', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );

    await client.adminSetFeedbackStatus('f1', 'done');
    expect(captured.url.path, '/admin/feedback/f1');
    expect(jsonDecode(captured.body), {'status': 'done'});
  });

  test('usage() parses the derived credit balance',
      () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        expect(req.url.path, '/usage');
        return http.Response(
          jsonEncode({
            'total': 12000,
            'features': {'chat': 12000},
            'credits': {'grant': 100, 'added': 50, 'used': 12,
                        'remaining': 138},
            'tokens_per_credit': 1000,
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
            'total': 0, 'features': {},
            'credits': {'grant': 100, 'added': 100, 'used': 0,
                        'remaining': 200},
            'tokens_per_credit': 1000,
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

  test('topUpCredits() maps a 402 to UpgradeRequiredException with the message',
      () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async => http.Response(
            jsonEncode({
              'detail': {'error': 'upgrade_required', 'message': 'Upgrade.'},
            }),
            402,
          )),
    );

    await expectLater(
      client.topUpCredits(),
      throwsA(isA<UpgradeRequiredException>()
          .having((e) => e.message, 'message', 'Upgrade.')),
    );
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

  test('refreshPhysicalAttributes() POSTs image_paths and parses the record',
      () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'ok': true,
            'fields': {
              'hair_color': {
                'value': 'black',
                'source': 'photo',
                'confidence': 'high',
              },
            },
            'photo_count': 3,
            'summary': 'Physical profile - hair: black.',
          }),
          200,
        );
      }),
    );

    final r = await client
        .refreshPhysicalAttributes(extraPaths: ['uploads/u1/a.jpg']);
    expect(captured.method, 'POST');
    expect(captured.url.path, '/physical-attributes/refresh');
    expect(jsonDecode(captured.body), {
      'image_paths': ['uploads/u1/a.jpg'],
    });
    expect(r.usageCapped, isFalse);
    expect(r.summary, 'Physical profile - hair: black.');
    expect(r.photoCount, 3);
    expect(r.attributes.single.field, 'hair_color');
    expect(r.attributes.single.value, 'black');
  });

  test('refreshPhysicalAttributes() surfaces the usage-capped signal', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient(
        (req) async => http.Response(jsonEncode({'usage_capped': true}), 200),
      ),
    );

    final r = await client.refreshPhysicalAttributes();
    expect(r.usageCapped, isTrue);
  });

  test('aiNotes() returns the wiki text and every photo Ayma has', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'text': '## Career\n\nBody',
            'photos': [
              {'url': 'https://cdn/p1.jpg', 'source': 'profile'},
              {'url': 'https://cdn/c1.jpg', 'source': 'chat'},
              {'url': '', 'source': 'chat'},
            ],
          }),
          200,
        ),
      ),
    );

    final n = await client.aiNotes();
    expect(n.text, '## Career\n\nBody');
    expect(n.photos, hasLength(2)); // the url-less row is dropped
    expect(n.photos.first.url, 'https://cdn/p1.jpg');
    expect(n.photos.first.source, 'profile');
    expect(n.photos.last.source, 'chat');
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

  // --- Profile completeness --------------------------------------------

  test('completeness() parses the score, intent and the next gaps', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'score': 62,
            'intent': 'long_term',
            'intent_set': false,
            'sections': [
              {
                'page_type': 'identity',
                'label': 'Identity & basics',
                'pct': 40,
                'answered': 2,
                'total': 7,
              },
            ],
            'next': [
              {
                'id': 'relationship_intent',
                'label': 'Relationship intent',
                'page_type': 'relationships',
                'kind': 'enum',
                'options': ['Casual', 'Long-term', 'Marriage', 'Not sure yet'],
                'scale': null,
                'ayma_prompt': "what kind of relationship they're here for",
                'weight': 5,
              },
            ],
            'updated_at': '2026-09-10T12:34:56Z',
          }),
          200,
        );
      }),
    );

    final c = await client.completeness();
    expect(captured.method, 'GET');
    expect(captured.url.path, '/completeness');
    expect(c.score, 62);
    expect(c.intent, 'long_term');
    expect(c.intentSet, isFalse);
    expect(c.isComplete, isFalse);
    expect(c.sections.single.label, 'Identity & basics');
    expect(c.sections.single.answered, 2);
    expect(c.sections.single.total, 7);
    expect(c.next.single.id, 'relationship_intent');
    expect(c.next.single.kind, 'enum');
    expect(c.next.single.options, contains('Not sure yet'));
    expect(c.next.single.aymaPrompt, contains('relationship'));
    expect(c.updatedAt, '2026-09-10T12:34:56Z');
  });

  test('completeness() tolerates missing keys', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final c = await client.completeness();
    expect(c.score, 0);
    expect(c.intent, 'long_term');
    expect(c.intentSet, isFalse);
    expect(c.sections, isEmpty);
    expect(c.next, isEmpty);
    expect(c.updatedAt, isNull);
  });

  test('completeness() reports a done profile via a stale literal-100 score',
      () async {
    // A cached completeness doc computed before the `complete` flag existed
    // still reports done, via the isComplete fallback.
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response(
          jsonEncode({'score': 100, 'intent_set': true}), 200)),
    );
    final c = await client.completeness();
    expect(c.isComplete, isTrue);
    expect(c.intentSet, isTrue);
  });

  test('completeness() reports done via the explicit complete flag, capped '
      'below 100', () async {
    // The real shape a current backend sends: full coverage of today's
    // question set caps at 95, never a literal 100 — `complete` is the
    // "done for now" signal, not the score.
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response(
          jsonEncode({'score': 95, 'complete': true, 'intent_set': true}),
          200)),
    );
    final c = await client.completeness();
    expect(c.score, 95);
    expect(c.isComplete, isTrue);
  });

  test('completeness() near-complete but not fully answered stays not-done',
      () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response(
          jsonEncode({'score': 93, 'complete': false, 'intent_set': true}),
          200)),
    );
    final c = await client.completeness();
    expect(c.isComplete, isFalse);
  });

  test('questionnaireTree() parses nodes incl. scale and status', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'intent': 'long_term',
            'intent_set': false,
            'score': 62,
            'nodes': [
              {
                'id': 'attachment_style',
                'page_type': 'personality',
                'branch': 'all',
                'label': 'Attachment style',
                'kind': 'enum',
                'options': ['Secure', 'Anxious-Preoccupied'],
                'scale': null,
                'weight': 5,
                'hard_filter': false,
                'dating_relevant': true,
                'ayma_prompt': 'how they bond under stress',
                'status': 'missing',
                'value': null,
                'source': null,
              },
              {
                'id': 'want_kids',
                'page_type': 'relationships',
                'label': 'Wants children',
                'kind': 'scale',
                'scale': {
                  'min': 1,
                  'max': 5,
                  'min_label': 'No',
                  'max_label': 'Yes',
                },
                'status': 'covered',
                'value': '4',
                'source': 'stated',
              },
              {'id': '', 'label': 'dropped'},
            ],
          }),
          200,
        );
      }),
    );

    final t = await client.questionnaireTree();
    expect(captured.method, 'GET');
    expect(captured.url.path, '/questionnaire');
    expect(t.intentSet, isFalse);
    expect(t.score, 62);
    expect(t.nodes, hasLength(2)); // the id-less node is dropped
    final a = t.nodes.first;
    expect(a.pageType, 'personality');
    expect(a.datingRelevant, isTrue);
    expect(a.isMissing, isTrue);
    expect(a.scale, isNull);
    final k = t.nodes[1];
    expect(k.kind, 'scale');
    expect(k.scale!.minLabel, 'No');
    expect(k.scale!.max, 5);
    expect(k.isCovered, isTrue);
    expect(k.value, '4');
    expect(k.source, 'stated');
    expect(t.byPageType.keys, containsAll(['personality', 'relationships']));
    expect(t.byPageType['relationships'], hasLength(1));
  });

  test('questionnaireTree() tolerates missing keys', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final t = await client.questionnaireTree();
    expect(t.nodes, isEmpty);
    expect(t.intent, 'long_term');
    expect(t.byPageType, isEmpty);
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

  test('unlikeProfile() POSTs /explore/unlike with the other uid', () async {
    late http.Request captured;
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );

    await client.unlikeProfile('her');
    expect(captured.method, 'POST');
    expect(captured.url.path, '/explore/unlike');
    expect(jsonDecode(captured.body), {'other_uid': 'her'});
  });

  test('unlikeProfile() throws on non-200', () async {
    final client = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((_) async => http.Response('boom', 500)),
    );
    expect(
      () => client.unlikeProfile('her'),
      throwsA(isA<ApiException>()),
    );
  });

  test('ProvenanceSource.fromMap parses session_id when present', () {
    final src = ProvenanceSource.fromMap({
      'date': '2026-08-19T00:00:00+00:00',
      'session_id': 'sess-abc',
    });
    expect(src.date, '2026-08-19T00:00:00+00:00');
    expect(src.sessionId, 'sess-abc');
  });

  test('ProvenanceSource.fromMap defaults session_id to empty when absent '
      '(old-format cache)', () {
    final src = ProvenanceSource.fromMap({'date': '2026-08-19T00:00:00+00:00'});
    expect(src.sessionId, '');
  });

  test('ChatMessage.fromMap parses created_at into a DateTime', () {
    final m = ChatMessage.fromMap({
      'role': 'user',
      'text': 'hi',
      'created_at': '2026-08-19T00:00:00+00:00',
    });
    expect(m.createdAt, DateTime.parse('2026-08-19T00:00:00+00:00'));
  });

  test('ChatMessage.fromMap parses the server-resolved image_url', () {
    // A generated image's ayma_generated/… path is not client-resolvable
    // (Storage rules), so the durable URL rides along in the payload.
    final m = ChatMessage.fromMap({
      'role': 'ayma',
      'text': "Here's a tree mapping your journey",
      'image_path': 'ayma_generated/u1/tree.png',
      'image_url': 'https://cdn.example/tree.png?token=t1',
    });
    expect(m.imagePath, 'ayma_generated/u1/tree.png');
    expect(m.imageUrl, 'https://cdn.example/tree.png?token=t1');
    // Older payloads without the field stay valid.
    expect(ChatMessage.fromMap({'role': 'ayma', 'text': 'hi'}).imageUrl, '');
  });

  test('ChatMessage.fromMap tolerates a missing/invalid created_at', () {
    expect(ChatMessage.fromMap({'role': 'user', 'text': 'hi'}).createdAt, isNull);
    expect(
      ChatMessage.fromMap({'role': 'user', 'text': 'hi', 'created_at': 'not-a-date'})
          .createdAt,
      isNull,
    );
  });

  test('syncBilling() POSTs the entitlement and parses the fresh balance',
      () async {
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'sync_status': 'synced_pro',
          'total': 0,
          'features': {},
          'credits': {'grant': 500, 'added': 0, 'used': 0, 'remaining': 1400},
          'tokens_per_credit': 1000,
          'plan': 'pro',
        }),
        200,
      );
    });
    final client =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    final usage = await client.syncBilling(
      productId: 'ayma_pro_monthly',
      expiresAtMs: 1893456000000,
      isTrial: true,
    );
    expect(captured.url.path, '/billing/sync');
    expect(captured.headers['Authorization'], startsWith('Bearer '));
    expect(jsonDecode(captured.body), {
      'product_id': 'ayma_pro_monthly',
      'expires_at_ms': 1893456000000,
      'is_trial': true,
    });
    expect(usage.creditsRemaining, 1400);
    expect(usage.plan, 'pro');
  });

  test('syncBilling() sends nulls when there is no active entitlement',
      () async {
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'sync_status': 'no_active',
          'total': 0,
          'features': {},
          'credits': {'grant': 500, 'added': 0, 'used': 0, 'remaining': 500},
          'tokens_per_credit': 1000,
          'plan': 'free',
        }),
        200,
      );
    });
    final client =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    final usage = await client.syncBilling();
    expect(jsonDecode(captured.body), {
      'product_id': null,
      'expires_at_ms': null,
      'is_trial': false,
    });
    expect(usage.plan, 'free');
  });

  group('image-variant display fields (perf phase 2)', () {
    test('ExploreCard parses photo_url_thumb and prefers it for the grid',
        () {
      final card = ExploreCard.fromMap({
        'uid': 'a',
        'name': 'Ash',
        'age': 29,
        'location': 'X',
        'photo_url': 'https://x/full.jpg',
        'photo_url_thumb': 'https://x/full__thumb_400.jpg',
      });
      expect(card.photoUrl, 'https://x/full.jpg');
      expect(card.photoUrlThumb, 'https://x/full__thumb_400.jpg');
      expect(card.gridPhotoUrl, 'https://x/full__thumb_400.jpg');
    });

    test('ExploreCard parses liked_me and round-trips it through toMap',
        () {
      final liker = ExploreCard.fromMap({
        'uid': 'a',
        'name': 'Ash',
        'age': 29,
        'location': 'X',
        'liked_me': true,
      });
      expect(liker.likedMe, isTrue);
      expect(liker.toMap()['liked_me'], isTrue);

      // Older responses without the field default to false.
      final plain = ExploreCard.fromMap({
        'uid': 'b',
        'name': 'Bo',
        'age': 30,
        'location': 'Y',
      });
      expect(plain.likedMe, isFalse);
      expect(plain.toMap()['liked_me'], isFalse);
    });

    test('ExploreCard grid falls back to the original without a thumb', () {
      final missing = ExploreCard.fromMap({
        'uid': 'a',
        'name': 'Ash',
        'age': 29,
        'location': 'X',
        'photo_url': 'https://x/full.jpg',
      });
      expect(missing.photoUrlThumb, isEmpty);
      expect(missing.gridPhotoUrl, 'https://x/full.jpg');

      final empty = ExploreCard.fromMap({
        'uid': 'a',
        'name': 'Ash',
        'age': 29,
        'location': 'X',
        'photo_url': 'https://x/full.jpg',
        'photo_url_thumb': '',
      });
      expect(empty.gridPhotoUrl, 'https://x/full.jpg');
    });

    test('PublicProfile parses aligned variant arrays', () {
      final p = PublicProfile.fromMap({
        'uid': 'her',
        'name': 'Dana',
        'age': 30,
        'location': 'Berlin',
        'photos': ['https://x/1.jpg', 'https://x/2.jpg'],
        'photos_thumb': ['https://x/1t.jpg', 'https://x/2t.jpg'],
        'photos_medium': ['https://x/1m.jpg', 'https://x/2m.jpg'],
        'pages': [],
      });
      expect(p.photosThumb, ['https://x/1t.jpg', 'https://x/2t.jpg']);
      expect(p.photosMedium, ['https://x/1m.jpg', 'https://x/2m.jpg']);
      expect(p.detailPhotos, ['https://x/1m.jpg', 'https://x/2m.jpg']);
      expect(p.thumbPhotos, ['https://x/1t.jpg', 'https://x/2t.jpg']);
    });

    test('PublicProfile falls back per entry when variants are missing', () {
      final missing = PublicProfile.fromMap({
        'uid': 'her',
        'name': 'Dana',
        'age': 30,
        'location': 'Berlin',
        'photos': ['https://x/1.jpg', 'https://x/2.jpg'],
        'pages': [],
      });
      expect(missing.detailPhotos, ['https://x/1.jpg', 'https://x/2.jpg']);
      expect(missing.thumbPhotos, ['https://x/1.jpg', 'https://x/2.jpg']);

      // Short arrays + empty entries fall back per index; extras ignored.
      final ragged = PublicProfile.fromMap({
        'uid': 'her',
        'name': 'Dana',
        'age': 30,
        'location': 'Berlin',
        'photos': ['https://x/1.jpg', 'https://x/2.jpg'],
        'photos_thumb': [''],
        'photos_medium': ['https://x/1m.jpg'],
        'pages': [],
      });
      expect(ragged.detailPhotos, ['https://x/1m.jpg', 'https://x/2.jpg']);
      expect(ragged.thumbPhotos, ['https://x/1.jpg', 'https://x/2.jpg']);
    });
  });

  group('Interactive timeout & deduplication (PERF_PLAN Phase 1)', () {
    test('interactive call throws 408 ApiException when timing out', () async {
      final mockHttp = MockClient((request) async {
        // Stalls longer than the custom 50ms test timeout
        await Future.delayed(const Duration(milliseconds: 200));
        return http.Response('{"cards": []}', 200);
      });
      final client = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
        interactiveTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        client.explore(),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 408)
            .having((e) => e.message, 'message', contains('timed out'))),
      );
    });

    test('concurrent identical GET requests are deduplicated to 1 network call',
        () async {
      var callCount = 0;
      final completer = Completer<http.Response>();

      final mockHttp = MockClient((request) async {
        callCount++;
        return completer.future;
      });

      final client = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
      );

      // Fire two identical GET calls concurrently
      final future1 = client.explore();
      final future2 = client.explore();

      // Allow microtask to resolve token and hit in-flight dedupe map
      await Future<void>.delayed(Duration.zero);
      expect(callCount, 1);

      // Complete the response
      completer.complete(http.Response('{"cards": []}', 200));

      final results = await Future.wait([future1, future2]);
      expect(results[0].cards, isEmpty);
      expect(results[1].cards, isEmpty);
      expect(callCount, 1);
    });

    test('idempotent GET retries once on 503 and succeeds on 2nd attempt',
        () async {
      var callCount = 0;
      final mockHttp = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          return http.Response('Service Unavailable', 503);
        }
        return http.Response('{"cards": []}', 200);
      });

      final client = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
      );

      final page = await client.explore();
      expect(page.cards, isEmpty);
      expect(callCount, 2);
    });

    test('photoPublish respects longTimeout over interactiveTimeout', () async {
      var received = false;
      final mockHttp = MockClient((request) async {
        if (request.url.path == '/wiki/photo-publish') {
          // Stalls past a 40ms interactive timeout but within 200ms longTimeout
          await Future.delayed(const Duration(milliseconds: 80));
          received = true;
          return http.Response('{"published": true}', 200);
        }
        return http.Response('{}', 200);
      });

      final client = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
        interactiveTimeout: const Duration(milliseconds: 40),
        longTimeout: const Duration(milliseconds: 200),
      );

      await client.photoPublish('https://example.com/p.jpg', source: 'chat');
      expect(received, isTrue);
    });

    // SWEEP451-M1: every match report showed "Couldn't load this report."
    // while the server logged `GET /match/{id} 200 OK` in ~13–15s. Root cause:
    // the 8s interactive budget aborted the read (TimeoutException -> 408), and
    // the bounded GET retry ran inside the same deadline so it could not heal a
    // deterministic >8s latency. The read paths must get the long budget.
    test('matchReport respects longTimeout over interactiveTimeout (/match/)',
        () async {
      var received = false;
      final mockHttp = MockClient((request) async {
        if (request.url.path.startsWith('/match/')) {
          // Stalls past a 40ms interactive timeout but within 200ms longTimeout
          await Future.delayed(const Duration(milliseconds: 80));
          received = true;
          return http.Response('{"match_id": "m1", "score": 0.8}', 200);
        }
        return http.Response('{}', 200);
      });

      final client = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
        interactiveTimeout: const Duration(milliseconds: 40),
        longTimeout: const Duration(milliseconds: 200),
      );

      final report = await client.matchReport('m1');
      expect(received, isTrue);
      expect(report?.matchId, 'm1');
    });

    test(
        'BudgetHttpClient routes /match/ and /report/match/ to the long budget, '
        'non-exempt GET to the interactive budget', () async {
      // Exercises `_timeoutFor` through the public `get`: an inner response
      // that stalls 80ms is aborted by a 40ms interactive budget but completes
      // under the 200ms long budget. The report read paths must take the long
      // budget; a non-exempt path must not.
      http.Client stall() => MockClient((request) async {
            await Future.delayed(const Duration(milliseconds: 80));
            return http.Response('{}', 200);
          });

      for (final path in ['/match/m1', '/report/match/m1']) {
        final client = BudgetHttpClient(
          stall(),
          interactiveTimeout: const Duration(milliseconds: 40),
          longTimeout: const Duration(milliseconds: 200),
        );
        final res = await client.get(Uri.parse('https://api.test$path'));
        expect(res.statusCode, 200, reason: '$path should use the long budget');
      }

      // A non-exempt GET at the same 80ms stall is aborted by the 40ms
      // interactive budget and surfaces as a 408 ApiException.
      final nonExempt = BudgetHttpClient(
        stall(),
        interactiveTimeout: const Duration(milliseconds: 40),
        longTimeout: const Duration(milliseconds: 200),
      );
      await expectLater(
        nonExempt.get(Uri.parse('https://api.test/explore')),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 408)),
      );
    });

    // Founder bug: the Appearance report showed "Couldn't finish the analysis.
    // Please try again." while staging logged `POST /appearance/report 200 OK`.
    // Same defect class as /match/ (SWEEP451-M1) and practice-start: the slow
    // multi-photo face+body build finished past the 8s interactive budget but
    // within the 55s long budget, so the client aborted it client-side. The
    // POST build must take the long budget; the fast GET re-open must not.
    test(
        'runAppearanceReport respects longTimeout — a 200 landing past the '
        'interactive budget but within the long budget succeeds', () async {
      var received = false;
      final mockHttp = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/appearance/report') {
          // Stalls past a 40ms interactive budget but within 200ms long budget.
          await Future.delayed(const Duration(milliseconds: 80));
          received = true;
          return http.Response(
              '{"report_id": "ap1", "usage_capped": false}', 200);
        }
        return http.Response('{}', 200);
      });

      final client = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
        interactiveTimeout: const Duration(milliseconds: 40),
        longTimeout: const Duration(milliseconds: 200),
      );

      final result = await client.runAppearanceReport();
      expect(received, isTrue);
      expect(result.reportId, 'ap1');
    });

    test(
        'BudgetHttpClient long-budget audit: every exempted build path takes '
        'the long budget; a quick GET like /explore stays interactive',
        () async {
      http.Client stall() => MockClient((request) async {
            // Stalls past the 40ms interactive budget but within the 200ms
            // long budget.
            await Future.delayed(const Duration(milliseconds: 80));
            return http.Response('{}', 200);
          });

      // Every path the slow-endpoint audit moved onto the long budget. If any
      // regressed to the interactive budget its 80ms stall would 408 here.
      const longBudgetPaths = <String>[
        '/wiki/photo-publish',
        '/appearance/report',
        '/deep-dive',
        '/face-report',
        '/body-report',
        '/physical-attributes/refresh',
        '/check-compatibility',
        '/media',
        '/media/photos/batch',
        '/verification/selfie',
        '/taste/pair',
        '/chat',
        '/practice/start',
        '/match/m1',
        '/report/match/m1',
        '/report/appearance/me/correct',
      ];
      for (final path in longBudgetPaths) {
        final client = BudgetHttpClient(
          stall(),
          interactiveTimeout: const Duration(milliseconds: 40),
          longTimeout: const Duration(milliseconds: 200),
        );
        final res = await client.get(Uri.parse('https://api.test$path'));
        expect(res.statusCode, 200,
            reason: '$path should take the long budget');
      }

      // Fast reads / genuinely-interactive paths must STAY on the interactive
      // budget: an 80ms stall must abort at 40ms as a 408. This guards against
      // over-exempting (a real hang would otherwise sit for the full 55s).
      const interactivePaths = <String>[
        '/explore',
        '/appearance/report/ap1', // GET re-open of a stored report (not the POST build)
        '/appearance/history',
        '/deep-dive/mine',
        '/physical-attributes',
        '/media/photos/order', // PUT reorder — a quick write
        '/chat/history',
      ];
      for (final path in interactivePaths) {
        final client = BudgetHttpClient(
          stall(),
          interactiveTimeout: const Duration(milliseconds: 40),
          longTimeout: const Duration(milliseconds: 200),
        );
        await expectLater(
          client.get(Uri.parse('https://api.test$path')),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 408)),
          reason: '$path should stay on the interactive budget',
        );
      }
    });
  });

  test('emailExists() posts the email unauthenticated and returns the flag',
      () async {
    late http.Request captured;
    final client = ApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'exists': true}), 200);
      }),
      // Signed OUT: the caller isn't authenticated yet — this must still work.
      auth: MockFirebaseAuth(),
    );

    expect(await client.emailExists('Test1@Gmail.com '), isTrue);
    expect(captured.url.path, '/auth/email-exists');
    expect(captured.headers['Authorization'], isNull);
    expect(jsonDecode(captured.body), {'email': 'Test1@Gmail.com '});
  });

  test('emailExists() returns false when the account is unknown', () async {
    final client = ApiClient(
      httpClient: MockClient((request) async {
        return http.Response(jsonEncode({'exists': false}), 200);
      }),
      auth: MockFirebaseAuth(),
    );

    expect(await client.emailExists('nobody@example.com'), isFalse);
  });

  test('emailExists() throws ApiException on non-200', () async {
    final client = ApiClient(
      httpClient: MockClient((request) async {
        return http.Response('boom', 503);
      }),
      auth: MockFirebaseAuth(),
    );

    expect(() => client.emailExists('a@b.com'), throwsA(isA<ApiException>()));
  });
}
