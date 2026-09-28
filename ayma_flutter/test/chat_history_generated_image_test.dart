// Founder bug 2026-09-27 (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2): Ayma generated
// an image in chat (generate_image); it displayed fine live, but after
// closing and reopening the chat it was GONE from the transcript. The
// persisted turn's `ayma_generated/{uid}/…` image_path is unreadable to the
// client Storage SDK (rules only open `uploads/{uid}`), so the old
// getDownloadURL() rehydration silently dropped the image. History rows now
// carry the durable server-resolved `image_url` — this test reloads a chat
// whose history holds an assistant image turn and asserts the image renders.

import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

const _generatedUrl =
    'https://firebasestorage.googleapis.com/v0/b/x/o/'
    'ayma_generated%2Fu1%2Ftree.png?alt=media&token=t1';

void main() {
  testWidgets(
      'a reloaded history payload with an assistant image turn renders '
      'the generated image', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({
              'messages': [
                {
                  'role': 'user',
                  'text': 'can you draw me a chart showing my story as a tree',
                  'image_path': '',
                  'image_url': '',
                  'created_at': '2026-09-27T18:10:00+00:00',
                },
                {
                  'role': 'ayma',
                  'text': "Here's a tree mapping your journey",
                  // The path the client SDK can't read…
                  'image_path': 'ayma_generated/u1/tree.png',
                  // …and the durable URL that must carry the image instead.
                  'image_url': _generatedUrl,
                  'tools': ['Generated an image'],
                  'created_at': '2026-09-27T18:10:05+00:00',
                },
              ],
              'next_before': null,
            }),
            200,
            headers: _jsonUtf8);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api = ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    // Both turns of the exchange survived the reload…
    expect(find.text("Here's a tree mapping your journey"), findsOneWidget);
    // …and the assistant turn renders its image, straight from the durable
    // URL — no client-side Storage resolution (which rules would refuse).
    final rendered = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .map((w) => w.imageUrl);
    expect(rendered, contains(_generatedUrl));
  });
}
