import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/thumbs_down_store.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ThumbsDownStore.instance.reset();
  });

  test('ThumbsDownStore records and persists per user', () async {
    expect(ThumbsDownStore.instance.isFlagged('Some reply'), isFalse);

    await ThumbsDownStore.instance.recordThumbsDown('user-1', 'Some reply');
    expect(ThumbsDownStore.instance.isFlagged('Some reply'), isTrue);

    // Reset in-memory state and reload from prefs
    ThumbsDownStore.instance.reset();
    expect(ThumbsDownStore.instance.isFlagged('Some reply'), isFalse);

    await ThumbsDownStore.instance.load('user-1');
    expect(ThumbsDownStore.instance.isFlagged('Some reply'), isTrue);

    // Another user has not flagged it
    await ThumbsDownStore.instance.load('user-2');
    expect(ThumbsDownStore.instance.isFlagged('Some reply'), isFalse);
  });

  testWidgets(
      'thumbs-down registers in-session and persists visibly after relaunch (D6)',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockUser = MockUser(uid: 'test-user-1');
    final auth = MockFirebaseAuth(mockUser: mockUser, signedIn: true);
    final submitted = <Map<String, dynamic>>[];

    final api = ApiClient(
      auth: auth,
      httpClient: MockClient((req) async {
        if (req.url.path == '/chat/history') {
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'role': 'user',
                  'text': 'Hello',
                  'created_at': '2026-11-01T10:00:00Z',
                },
                {
                  'role': 'ayma',
                  'text': 'Here is my advice for you.',
                  'created_at': '2026-11-01T10:00:05Z',
                },
              ],
              'next_before': null,
            }),
            200,
            headers: _jsonUtf8,
          );
        }
        if (req.url.path == '/feedback') {
          submitted.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'ok': true, 'id': 'fb-1'}), 200, headers: _jsonUtf8);
        }
        return http.Response('{}', 200, headers: _jsonUtf8);
      }),
    );

    // 1. Initial launch: reply shows unmarked outline icon
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(apiClient: api, auth: auth),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.thumb_down_alt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down_alt), findsNothing);
    expect(find.text('noted'), findsNothing);

    // 2. Tap thumbs down
    await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    expect(submitted.single['quote'], 'Here is my advice for you.');
    expect(find.byIcon(Icons.thumb_down_alt), findsOneWidget);
    expect(find.text('noted'), findsOneWidget);

    // 3. Relaunch (simulate force-stop + relaunch):
    // In-memory cache is reset, new screen is mounted with same user
    ThumbsDownStore.instance.reset();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(apiClient: api, auth: auth),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Relaunch must visibly render the filled icon and 'noted'
    expect(find.byIcon(Icons.thumb_down_alt), findsOneWidget);
    expect(find.text('noted'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down_alt_outlined), findsNothing);
  });
}
