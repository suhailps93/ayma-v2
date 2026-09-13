import 'dart:convert';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('photo context stays above composer and below conversation', (
    tester,
  ) async {
    final api = ApiClient(
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({'messages': [], 'next_before': null}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      auth: MockFirebaseAuth(signedIn: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          apiClient: api,
          photoUrl: 'https://example.com/photo.jpg',
          photoSource: 'chat',
        ),
      ),
    );
    await tester.pumpAndSettle();
    void checkPlacement() {
      final label = find.text('Talking about this photo');
      final conversation = find.text('Say hello to start a conversation.');
      final input = find.byType(TextField);
      expect(label, findsOneWidget);
      expect(
        tester.getTopLeft(label).dy,
        greaterThan(tester.getBottomLeft(conversation).dy),
      );
      expect(
        tester.getBottomLeft(label).dy,
        lessThan(tester.getTopLeft(input).dy),
      );
      expect(
        tester.getTopLeft(input).dy - tester.getBottomLeft(label).dy,
        lessThan(90),
      );
      expect(tester.takeException(), isNull);
    }

    checkPlacement();
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    checkPlacement();
  });
}
