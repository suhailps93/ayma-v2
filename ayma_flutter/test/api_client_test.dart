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
    expect(captured.url.path, '/chat');
    expect(captured.headers['Authorization'], startsWith('Bearer '));
    expect(jsonDecode(captured.body),
        {'message': 'hello', 'session_id': 's-unit-000001', 'recent_turns': []});
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
      'recent_turns': [
        {'role': 'user', 'text': 'said out loud'},
        {'role': 'ayma', 'text': 'mm-hm'},
      ],
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
}
