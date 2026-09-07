import 'dart:convert';

import 'package:ayma_flutter/routing/entry.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _apiWithHistory(
  http.Response Function(http.Request request) onHistory,
) {
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') return onHistory(request);
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  test('entryRouteFor maps every session_mode to a real screen path', () {
    expect(entryRouteFor('active'), MainShellScreen.path);
    expect(entryRouteFor('interview'), PreboardingFlowScreen.path);
    expect(entryRouteFor('marketing'), ChatScreen.path);
    expect(entryRouteFor('anything-else'), ChatScreen.path);
    // A missing/empty mode is a malformed response, not "pre-signup" — a
    // signed-in user must not be dumped into the marketing chat.
    expect(entryRouteFor(''), MainShellScreen.path);
  });

  testWidgets('chat shell renders and accepts typed text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200),
    );

    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Say hello to start a conversation.'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello ayma');
    await tester.pump();
    expect(find.text('hello ayma'), findsOneWidget);

    // Step 14: the voice mic button is present in the composer.
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
  });

  testWidgets(
      'a failed history load shows a distinct error + retry, not "say hello"',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var calls = 0;
    final api = _apiWithHistory((_) {
      calls++;
      // Fail the first load (e.g. cold-start 503 / rate-limit 429), then
      // succeed on retry.
      if (calls == 1) return http.Response('nope', 503);
      return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200);
    });

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    // Not the empty-history copy — a real error with a way to recover.
    expect(find.text('Say hello to start a conversation.'), findsNothing);
    expect(
        find.text("Couldn't load your conversation history."), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(
        find.text("Couldn't load your conversation history."), findsNothing);
    expect(find.text('Say hello to start a conversation.'), findsOneWidget);
  });

  testWidgets('history turns from the server seed the transcript on open',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
        jsonEncode({
          'messages': [
            {'role': 'user', 'text': 'hey from last week', 'image_path': ''},
            {'role': 'ayma', 'text': 'welcome back', 'image_path': ''},
          ],
          'next_before': null,
        }),
        200,
      ),
    );

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Say hello to start a conversation.'), findsNothing);
    expect(find.text('hey from last week'), findsOneWidget);
    expect(find.text('welcome back'), findsOneWidget);
  });

  testWidgets('an Ayma turn ending with a [face_report:id] marker strips it '
      'from the shown text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
        jsonEncode({
          'messages': [
            {
              'role': 'ayma',
              'text': 'Here is your read. [face_report:abc123]',
              'image_path': '',
            },
          ],
          'next_before': null,
        }),
        200,
      ),
    );

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    // The marker is stripped; the inline report card fetches the stored
    // report itself (and shows nothing if there isn't one).
    expect(find.textContaining('Here is your read'), findsOneWidget);
    expect(find.textContaining('face_report'), findsNothing);
  });

  testWidgets('preboarding flow starts on the name step with a gated Next',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: PreboardingFlowScreen()),
    );

    expect(find.text('About you (1/6)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'First name'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Last name'), findsOneWidget);

    // First name alone no longer advances — last name is required too.
    await tester.enterText(
        find.widgetWithText(TextField, 'First name'), 'Alex');
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('About you (1/6)'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    await tester.enterText(
        find.widgetWithText(TextField, 'Last name'), 'Rivera');
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('About you (2/6)'), findsOneWidget);
    expect(find.textContaining('date of birth'), findsOneWidget);
  });
}
