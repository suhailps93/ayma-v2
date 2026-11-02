import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/widgets/message_timestamp.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

void main() {
  testWidgets(
    'ChatScreen renders time labels and date divider chips for dated history turns',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final d1 = DateTime.utc(2026, 10, 30, 9, 41);
      final d2 = DateTime.utc(2026, 10, 31, 14, 15);

      final api = ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((req) async {
          if (req.url.path == '/chat/history') {
            return http.Response(
              jsonEncode({
                'messages': [
                  {
                    'role': 'user',
                    'text': 'User message from yesterday',
                    'created_at': d1.toIso8601String(),
                  },
                  {
                    'role': 'ayma',
                    'text': 'Ayma reply from today',
                    'created_at': d2.toIso8601String(),
                  },
                ],
                'next_before': null,
              }),
              200,
              headers: _jsonUtf8,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(apiClient: api),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('User message from yesterday'), findsOneWidget);
      expect(find.text('Ayma reply from today'), findsOneWidget);

      // Verify time labels are rendered
      expect(find.text(formatMessageTime(d1)), findsOneWidget);
      expect(find.text(formatMessageTime(d2)), findsOneWidget);

      // Verify date divider chips exist for both days
      expect(find.byType(DateDividerChip), findsNWidgets(2));
    },
  );

  testWidgets(
    'ChatScreen gracefully handles turns with null createdAt (live turns)',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = TranscriptStore();
      final api = ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((req) async {
          if (req.url.path == '/chat/history') {
            return http.Response(
              jsonEncode({'messages': [], 'next_before': null}),
              200,
              headers: _jsonUtf8,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(
              apiClient: api,
              transcriptStore: store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Live turns added after history loads
      store.addTurn(TurnRole.user, 'Live user message', TurnSource.text);
      store.addTurn(TurnRole.ayma, 'Live Ayma reply', TurnSource.text);
      await tester.pumpAndSettle();

      expect(find.text('Live user message'), findsOneWidget);
      expect(find.text('Live Ayma reply'), findsOneWidget);

      // No date divider chip invented
      expect(find.byType(DateDividerChip), findsNothing);
    },
  );
}
