import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// A tiny, real, checked-in PNG (see `test/fixtures/`) — Flutter's image
/// codec needs decodable bytes to render `Image.file` without erroring.
const _fixturePath = 'test/fixtures/tiny.png';

/// Returns [path] for every capture — stands in for the real picker so the
/// test can drive "attach a photo" without touching a platform channel.
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this.path);
  final String path;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async =>
      XFile(path);
}

/// A `ChatService` whose upload never resolves until the test completes
/// [uploadGate] — simulates a slow Storage upload so a test can assert what
/// the chat shows *before* it finishes.
class _DelayedChatService extends ChatService {
  final uploadGate = Completer<ChatImageUpload>();
  final calls = <File>[];

  @override
  Future<ChatImageUpload> uploadChatImage(File file) {
    calls.add(file);
    return uploadGate.future;
  }
}

class _FailingChatService extends ChatService {
  @override
  Future<ChatImageUpload> uploadChatImage(File file) =>
      Future<ChatImageUpload>.error(StateError('upload failed'));
}

http.Response _historyResponse() => http.Response(
    jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
    headers: _jsonUtf8);

Future<void> _attachFixturePhoto(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose from library'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a chat photo turn appears immediately, before the upload resolves',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') return _historyResponse();
      if (request.url.path == '/chat/stream') {
        final body = [
          'data: ${jsonEncode({
                'type': 'reply',
                'text': 'Nice photo!',
                'tools_used': <String>[],
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api = ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    final chat = _DelayedChatService();

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        chatService: chat,
        imagePicker: _FakeImagePicker(_fixturePath),
      ),
    ));
    await tester.pumpAndSettle();

    await _attachFixturePhoto(tester);

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump(); // enough for `_send` to reach the still-open upload

    // The bubble is already there, rendered straight from the local file —
    // the Storage upload the send is waiting on hasn't resolved yet.
    expect(chat.calls, hasLength(1));
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
      findsOneWidget,
    );

    // Let the upload — and the rest of the send — finish.
    chat.uploadGate.complete(const ChatImageUpload(
      storagePath: 'uploads/u1/chat_1.jpg',
      downloadUrl: 'https://example.com/photo.jpg',
    ));
    await tester.pumpAndSettle();

    expect(find.text('Nice photo!'), findsOneWidget);
  });

  testWidgets(
      'a failed upload removes the optimistic turn and shows the error',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') return _historyResponse();
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api = ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    final chat = _FailingChatService();

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        chatService: chat,
        imagePicker: _FakeImagePicker(_fixturePath),
      ),
    ));
    await tester.pumpAndSettle();

    await _attachFixturePhoto(tester);

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
      findsNothing,
    );
    expect(find.text("Couldn't upload that image."), findsOneWidget);
  });
}
