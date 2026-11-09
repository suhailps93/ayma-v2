import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/feedback_draft_card.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
const _fixturePath = 'test/fixtures/tiny.png';

/// Records every image upload and returns a fixed storage path, so the card
/// can run its "upload then POST" path without touching Firebase Storage.
class _FakeChatService extends ChatService {
  final List<String> uploaded = [];

  @override
  Future<ChatImageUpload> uploadImage(file, {String prefix = 'chat'}) async {
    uploaded.add(prefix);
    return const ChatImageUpload(
      storagePath: 'uploads/me/feedback_1.png',
      downloadUrl: 'https://example.test/feedback_1.png',
    );
  }
}

class _FakePicker extends ImagePicker {
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async =>
      XFile(_fixturePath);
}

/// Builds an [ApiClient] whose POSTs are captured into [captured].
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

void main() {
  testWidgets('renders the drafted card with kind, title, body and actions',
      (tester) async {
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'feature',
      title: 'Dark map',
      body: 'A dark theme for the Explore map',
      api: _api([]),
      chatService: _FakeChatService(),
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
    )));

    expect(find.text('Feature request'), findsOneWidget);
    expect(find.text('Dark map'), findsOneWidget);
    expect(find.text('A dark theme for the Explore map'), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-send')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-not-now')), findsOneWidget);
    // Not editable until Edit is tapped.
    expect(find.byKey(const ValueKey('feedback-body-field')), findsNothing);
  });

  testWidgets('Edit makes the title and body editable', (tester) async {
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'bug',
      title: 'Orb flickers',
      body: 'it flickers',
      api: _api([]),
      chatService: _FakeChatService(),
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
    )));

    await tester.tap(find.byKey(const ValueKey('feedback-edit')));
    await tester.pump();

    expect(find.byKey(const ValueKey('feedback-title-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-body-field')), findsOneWidget);
  });

  testWidgets('Not now dismisses the card and fires onDismiss',
      (tester) async {
    var dismissed = false;
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'feature',
      title: 'X',
      body: 'something',
      api: _api([]),
      chatService: _FakeChatService(),
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
      onDismiss: () => dismissed = true,
    )));

    await tester.tap(find.byKey(const ValueKey('feedback-not-now')));
    await tester.pump();

    expect(dismissed, isTrue);
    expect(find.byKey(const ValueKey('feedback-send')), findsNothing);
  });

  testWidgets('add then remove a screenshot', (tester) async {
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'bug',
      title: 'X',
      body: 'broke',
      api: _api([]),
      chatService: _FakeChatService(),
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
    )));

    expect(find.byKey(const ValueKey('feedback-add-shot')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feedback-add-shot')));
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback-remove-shot')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-add-shot')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('feedback-remove-shot')));
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback-add-shot')), findsOneWidget);
  });

  testWidgets('a card restored as sent shows the sent view, not a draft',
      (tester) async {
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'bug',
      title: 'Orb flickers',
      body: 'it flickers',
      resolvedOutcome: 'sent',
      api: _api([]),
      chatService: _FakeChatService(),
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
    )));

    expect(find.byKey(const ValueKey('feedback-sent')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-send')), findsNothing);
  });

  testWidgets('a card restored as dismissed renders nothing',
      (tester) async {
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'bug',
      title: 'Orb flickers',
      body: 'it flickers',
      resolvedOutcome: 'dismissed',
      api: _api([]),
      chatService: _FakeChatService(),
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
    )));

    expect(find.byKey(const ValueKey('feedback-send')), findsNothing);
    expect(find.byKey(const ValueKey('feedback-sent')), findsNothing);
  });

  testWidgets('Send POSTs the edited values plus the screenshot path',
      (tester) async {
    final captured = <Map<String, dynamic>>[];
    var sent = false;
    final chat = _FakeChatService();
    await tester.pumpWidget(_wrap(FeedbackDraftCard(
      kind: 'bug',
      title: 'Orb flickers',
      body: 'original body',
      screen: 'messages',
      api: _api(captured),
      chatService: chat,
      picker: _FakePicker(),
      appVersionOverride: '1.30.0',
      platformOverride: 'android',
      onSent: () => sent = true,
    )));

    // Edit the body.
    await tester.tap(find.byKey(const ValueKey('feedback-edit')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('feedback-body-field')), 'edited body');

    // Attach a screenshot.
    await tester.tap(find.byKey(const ValueKey('feedback-add-shot')));
    await tester.pump();

    // Send.
    await tester.tap(find.byKey(const ValueKey('feedback-send')));
    await tester.pumpAndSettle();

    expect(chat.uploaded, ['feedback']);
    expect(captured, hasLength(1));
    final req = captured.single;
    expect(req['path'], '/feedback/submit');
    final body = req['body'] as Map<String, dynamic>;
    expect(body['kind'], 'bug');
    expect(body['body'], 'edited body');
    expect(body['source'], 'chat_card');
    expect(body['screen'], 'messages');
    expect(body['platform'], 'android');
    expect(body['app_version'], '1.30.0');
    expect(body['screenshot_paths'], ['uploads/me/feedback_1.png']);
    expect(sent, isTrue);
    expect(find.byKey(const ValueKey('feedback-sent')), findsOneWidget);
  });
}
