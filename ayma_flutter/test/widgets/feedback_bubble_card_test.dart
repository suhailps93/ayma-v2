import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/feedback_bubble.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/feedback_bubble_card.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

ApiClient _api(List<Map<String, dynamic>> captured) => ApiClient(
      httpClient: MockClient((req) async {
        captured.add({
          'path': req.url.path,
          'body': jsonDecode(req.body) as Map<String, dynamic>,
        });
        return http.Response(jsonEncode({'ok': true, 'id': 'x'}), 200,
            headers: _jsonUtf8);
      }),
      auth: MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'me'),
      ),
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

FeedbackBubbleCard _card(
  List<Map<String, dynamic>> captured, {
  FeedbackBubbleTrigger trigger = FeedbackBubbleTrigger.explicit,
  String initialText = '',
  String fillText = '',
  int fillRevision = 0,
  VoidCallback? onDismiss,
  VoidCallback? onSent,
  File? screenshotFile,
  String? screenshotPath,
  bool screenshotFailed = false,
}) =>
    FeedbackBubbleCard(
      trigger: trigger,
      initialText: initialText,
      fillText: fillText,
      fillRevision: fillRevision,
      api: _api(captured),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
      onDismiss: onDismiss,
      onSent: onSent,
      screenshotFile: screenshotFile,
      screenshotPath: screenshotPath,
      screenshotFailed: screenshotFailed,
    );

void main() {
  testWidgets('renders the ask: prompt, field, submit, dismiss, tell-Ayma line',
      (tester) async {
    await tester.pumpWidget(_wrap(_card([])));

    expect(find.text('What feedback would you like to share?'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-bubble-field')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-bubble-submit')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-bubble-dismiss')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-bubble-dictate')),
        findsNothing);
    expect(
        find.text(
            'You can also just tell Ayma — your words land here for review.'),
        findsOneWidget);
  });

  testWidgets('frustration trigger uses the softer prompt', (tester) async {
    await tester.pumpWidget(_wrap(_card(
      [],
      trigger: FeedbackBubbleTrigger.frustration,
    )));
    expect(
        find.text(
            'Sounds like I missed the mark — want to tell us what went wrong?'),
        findsOneWidget);
  });

  testWidgets('submit POSTs the typed feedback as source chat_card',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    var sent = false;
    await tester.pumpWidget(_wrap(_card(
      captured,
      onSent: () => sent = true,
    )));

    await tester.enterText(
        find.byKey(const ValueKey('feedback-bubble-field')),
        'The Explore map loads slowly');
    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();

    expect(captured, hasLength(1));
    expect(captured.single['path'], '/feedback/submit');
    final body = captured.single['body'] as Map<String, dynamic>;
    expect(body['source'], 'chat_card');
    expect(body['body'], 'The Explore map loads slowly');
    expect(body['kind'], 'feature');
    expect(sent, isTrue);
    expect(find.byKey(const ValueKey('feedback-bubble-sent')),
        findsOneWidget);

    // The confirmation is transient: it clears itself after a brief
    // linger instead of sitting in the thread forever.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('feedback-bubble-sent')),
        findsNothing);
  });

  testWidgets('the sent confirmation dismisses itself after a brief linger',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    var dismissed = false;
    await tester.pumpWidget(_wrap(_card(
      captured,
      initialText: 'orb flickers',
      onDismiss: () => dismissed = true,
    )));

    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect(find.byKey(const ValueKey('feedback-bubble-sent')),
        findsOneWidget);
    expect(dismissed, isFalse);

    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('feedback-bubble-sent')),
        findsNothing);
    expect(dismissed, isTrue);
  });

  testWidgets('a recreated card restored as sent shows the sent view',
      (tester) async {
    await tester.pumpWidget(_wrap(FeedbackBubbleCard(
      trigger: FeedbackBubbleTrigger.explicit,
      initiallySent: true,
      api: _api([]),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
    )));

    expect(find.byKey(const ValueKey('feedback-bubble-sent')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-bubble-submit')),
        findsNothing);

    // A restored sent view still expires on its own.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('feedback-bubble-sent')),
        findsNothing);
  });

  testWidgets('prefill from the trigger phrase lands in the field',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(_card(
      captured,
      initialText: 'the mic keeps dropping',
    )));
    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect((captured.single['body'] as Map)['body'],
        'the mic keeps dropping');
  });

  testWidgets('dismiss writes nothing and fires onDismiss', (tester) async {
    final captured = <Map<String, dynamic>>[];
    var dismissed = false;
    await tester.pumpWidget(_wrap(_card(
      captured,
      initialText: 'something',
      onDismiss: () => dismissed = true,
    )));

    await tester.tap(find.byKey(const ValueKey('feedback-bubble-dismiss')));
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
    expect(captured, isEmpty);
    expect(find.byKey(const ValueKey('feedback-bubble-submit')),
        findsNothing);
  });

  testWidgets('conversational fill lands in the field for review',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(_card(captured)));
    await tester.pumpWidget(_wrap(_card(
      captured,
      fillText: 'the orb flickers on the messages tab',
      fillRevision: 1,
    )));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect((captured.single['body'] as Map)['body'],
        'the orb flickers on the messages tab');
  });

  testWidgets('empty submit files nothing', (tester) async {
    final captured = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(_card(captured)));
    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, isEmpty);
  });

  testWidgets('auto screenshot thumbnail shows and submits its path',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(_card(
      captured,
      initialText: 'orb flickers',
      screenshotFile: File('test/fixtures/tiny.png'),
      screenshotPath: 'uploads/me/feedback_9.png',
    )));

    expect(find.byKey(const ValueKey('feedback-bubble-shot')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-bubble-remove-shot')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect((captured.single['body'] as Map)['screenshot_paths'],
        ['uploads/me/feedback_9.png']);
  });

  testWidgets('removing the screenshot submits without it', (tester) async {
    final captured = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(_card(
      captured,
      initialText: 'orb flickers',
      screenshotFile: File('test/fixtures/tiny.png'),
      screenshotPath: 'uploads/me/feedback_9.png',
    )));

    await tester
        .tap(find.byKey(const ValueKey('feedback-bubble-remove-shot')));
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback-bubble-shot')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect((captured.single['body'] as Map)['screenshot_paths'], isEmpty);
  });

  testWidgets('failed capture says so and submission still works',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(_card(
      captured,
      initialText: 'orb flickers',
      screenshotFailed: true,
    )));

    expect(find.byKey(const ValueKey('feedback-bubble-shot-failed')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feedback-bubble-submit')));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect((captured.single['body'] as Map)['screenshot_paths'], isEmpty);
  });
}
