import 'dart:convert';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:ayma_flutter/services/api_client.dart';

void main() {
  test('clampChatContext truncates only over-cap strings', () {
    expect(clampChatContext('short', 4000), 'short');
    expect(clampChatContext('x' * 4500, 4000).length, 4000);
    expect(clampChatContext('', 3200), '');
  });

  test('clampRecentTurns clamps text and keeps roles', () {
    final out = clampRecentTurns([
      {'role': 'ayma', 'text': 'x' * 4642},
      {'role': 'user', 'text': 'hi'},
    ]);
    expect(out[0]['role'], 'ayma');
    expect(out[0]['text']!.length, 4000);
    expect(out[1], {'role': 'user', 'text': 'hi'});
  });

  test('buildChatRequestBody clamps context but not the message', () {
    final longMessage = 'm' * 4500;
    final body = buildChatRequestBody(
      message: longMessage,
      recentTurns: [
        {'role': 'ayma', 'text': 'x' * 4642},
      ],
      screenNote: 'n' * 900,
      storyPassage: 'p' * 9000,
      deepDiveTarget: 't' * 3000,
    );
    expect(body['message'], longMessage);
    expect((body['recent_turns'] as List).single['text'].length, 4000);
    expect((body['screen_note'] as String).length, 500);
    expect((body['story_passage'] as String).length, 8000);
    expect((body['deep_dive_target'] as String).length, 2200);
    // The whole-page `screen_detail`/`screen_visible` snapshot is no longer
    // part of the wire body — only the page REFERENCE rides inline.
    expect(body.containsKey('screen_detail'), isFalse);
    expect(body.containsKey('screen_visible'), isFalse);
  });

  test('chat() sends clamped context on the wire', () async {
    late http.Request captured;
    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'reply': 'ok'}), 200);
    });
    final client = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );
    await client.chat(
      'hello',
      recentTurns: [
        {'role': 'ayma', 'text': 'x' * 4642},
      ],
      storyPassage: 'p' * 9000,
    );
    final sent = jsonDecode(captured.body) as Map<String, dynamic>;
    expect((sent['recent_turns'] as List).single['text'].length, 4000);
    expect((sent['story_passage'] as String).length, 8000);
    expect(sent['message'], 'hello');
  });

  test('chatStream() sends clamped context on the wire', () async {
    late http.BaseRequest captured;
    final sse = 'data: {"type":"reply","text":"hi","tools_used":[]}\n\n';
    final client = ApiClient(
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response.bytes(utf8.encode(sse), 200);
      }),
      auth: MockFirebaseAuth(signedIn: true),
    );
    await client
        .chatStream(
          'hey',
          recentTurns: [
            {'role': 'ayma', 'text': 'y' * 5000},
          ],
          storyPassage: 'p' * 9000,
        )
        .toList();
    final sent =
        jsonDecode((captured as http.Request).body) as Map<String, dynamic>;
    expect((sent['recent_turns'] as List).single['text'].length, 4000);
    expect((sent['story_passage'] as String).length, 8000);
  });
}
