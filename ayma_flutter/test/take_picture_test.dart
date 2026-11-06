import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:ayma_flutter/services/take_picture_intent.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// A tiny, real, checked-in PNG (see `test/fixtures/`) — Flutter's image
/// codec needs decodable bytes to render `Image.file` without erroring.
const _fixturePath = 'test/fixtures/tiny.png';

/// Records every capture request; stands in for the real camera so the
/// test can drive "take a picture" without touching a platform channel.
/// Can be told to throw (permission denied) or return null (camera
/// closed) to exercise the graceful-degradation paths.
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this.path);

  final String path;
  Object? error;
  bool returnNull = false;
  final List<({ImageSource source, CameraDevice device})> calls = [];

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    calls.add((source: source, device: preferredCameraDevice));
    if (error != null) throw error!;
    if (returnNull) return null;
    return XFile(path);
  }
}

/// A `ChatService` that records uploads; subclasses decide when (or
/// whether) an upload resolves.
abstract class _RecordingChatService extends ChatService {
  final calls = <File>[];

  @override
  Future<ChatImageUpload> uploadChatImage(File file) {
    calls.add(file);
    return resolveUpload();
  }

  Future<ChatImageUpload> resolveUpload();
}

class _ImmediateChatService extends _RecordingChatService {
  @override
  Future<ChatImageUpload> resolveUpload() async => const ChatImageUpload(
        storagePath: 'uploads/u1/chat_9.jpg',
        downloadUrl: 'https://example.com/captured.jpg',
      );
}

/// An upload that never resolves until the test completes [uploadGate] —
/// lets a test assert what the chat shows while the captured photo is
/// still uploading (the local file, rendered directly).
class _GatedChatService extends _RecordingChatService {
  final uploadGate = Completer<ChatImageUpload>();

  @override
  Future<ChatImageUpload> resolveUpload() => uploadGate.future;
}

http.Response _historyResponse() => http.Response(
    jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
    headers: _jsonUtf8);

/// Pumps a [ChatScreen] wired to a MockClient that records `/chat/stream`
/// bodies and replies with [reply] — the vision reaction Ayma gives after
/// seeing the captured photo through the existing `/chat` vision path.
Future<({_FakeImagePicker picker, _RecordingChatService chat})> _pumpChat(
  WidgetTester tester, {
  required List<Map<String, dynamic>> streamBodies,
  String reply = 'Lovely shot!',
  _RecordingChatService? chatService,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') return _historyResponse();
    if (request.url.path == '/chat/stream') {
      streamBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      final body = [
        'data: ${jsonEncode({
              'type': 'reply',
              'text': reply,
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
    httpClient: mockHttp,
    auth: MockFirebaseAuth(signedIn: true),
  );
  final chat = chatService ?? _ImmediateChatService();
  final picker = _FakeImagePicker(_fixturePath);

  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(apiClient: api, chatService: chat, imagePicker: picker),
  ));
  await tester.pumpAndSettle();
  return (picker: picker, chat: chat);
}

Future<void> _typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
  await tester.pumpAndSettle();
}

void main() {
  group('TakePictureIntent', () {
    test('matches the trigger and its close variants', () {
      for (final text in [
        'take a picture',
        'Take a picture.',
        'please take a photo',
        'snap a picture',
        'capture a photo',
        'take a picture with the front camera',
        'shoot a pic',
      ]) {
        expect(TakePictureIntent.isRequest(text), isTrue, reason: text);
      }
    });

    test('does not match ordinary chat about pictures', () {
      for (final text in [
        'I love this picture',
        'show me the picture',
        'that photo is nice',
        'pictures',
        '',
      ]) {
        expect(TakePictureIntent.isRequest(text), isFalse, reason: text);
      }
    });

    test('parses camera answers and embedded camera choices', () {
      expect(TakePictureIntent.parseCameraAnswer('front'), 'front');
      expect(TakePictureIntent.parseCameraAnswer('Back camera'), 'back');
      expect(TakePictureIntent.parseCameraAnswer('the rear one'), 'back');
      expect(TakePictureIntent.parseCameraAnswer('selfie'), 'front');
      expect(TakePictureIntent.parseCameraAnswer('yes please'), isNull);
      expect(TakePictureIntent.parseCameraAnswer('front door'), isNull);
      expect(
        TakePictureIntent.cameraMentionedIn(
            'take a picture with the front camera'),
        'front',
      );
      expect(
        TakePictureIntent.cameraMentionedIn('take a picture'),
        isNull,
      );
    });

    test('maps choices to picker camera devices', () {
      expect(TakePictureIntent.deviceFor('front'), CameraDevice.front);
      expect(TakePictureIntent.deviceFor('back'), CameraDevice.rear);
    });
  });

  testWidgets(
      'trigger asks front or back; tapping Front captures with the front '
      'camera and the photo lands in the chat for Ayma to react to',
      (tester) async {
    final streamBodies = <Map<String, dynamic>>[];
    final gated = _GatedChatService();
    final rig =
        await _pumpChat(tester, streamBodies: streamBodies, chatService: gated);

    await _typeAndSend(tester, 'take a picture');

    // The confirm step: Ayma asked in the transcript AND the tappable
    // options are up; nothing has been captured yet.
    expect(find.text(TakePictureIntent.confirmQuestion), findsWidgets);
    expect(find.text('Front camera'), findsOneWidget);
    expect(find.text('Back camera'), findsOneWidget);
    expect(rig.picker.calls, isEmpty);
    expect(streamBodies, isEmpty);

    await tester.tap(find.text('Front camera'));
    await tester.pump();
    await tester.pump();

    // Captured with the chosen (front) camera, through the camera source.
    expect(rig.picker.calls, hasLength(1));
    expect(rig.picker.calls.single.source, ImageSource.camera);
    expect(rig.picker.calls.single.device, CameraDevice.front);

    // The photo is already in the conversation as a visible image turn,
    // rendered straight from the local file while its upload is pending.
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
      findsOneWidget,
    );
    expect(gated.calls, hasLength(1));

    // Let the upload — and the rest of the send — finish: /chat got the
    // uploaded image_path (the vision path) and Ayma's reply to what she
    // saw is on screen.
    gated.uploadGate.complete(const ChatImageUpload(
      storagePath: 'uploads/u1/chat_9.jpg',
      downloadUrl: 'https://example.com/captured.jpg',
    ));
    await tester.pumpAndSettle();
    expect(streamBodies, hasLength(1));
    expect(streamBodies.single['image_path'], 'uploads/u1/chat_9.jpg');
    expect(find.text('Lovely shot!'), findsOneWidget);
  });

  testWidgets(
      'a spoken/typed camera answer after the question captures with that '
      'camera', (tester) async {
    final streamBodies = <Map<String, dynamic>>[];
    final rig = await _pumpChat(tester, streamBodies: streamBodies);

    await _typeAndSend(tester, 'take a picture');
    expect(find.text('Back camera'), findsOneWidget);

    // Dismiss the sheet without tapping: the question stays outstanding.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(rig.picker.calls, isEmpty);

    await _typeAndSend(tester, 'back');

    expect(rig.picker.calls, hasLength(1));
    expect(rig.picker.calls.single.device, CameraDevice.rear);
    expect(streamBodies.single['image_path'], 'uploads/u1/chat_9.jpg');
  });

  testWidgets(
      'a request that already names the camera captures without re-asking',
      (tester) async {
    final streamBodies = <Map<String, dynamic>>[];
    final rig = await _pumpChat(tester, streamBodies: streamBodies);

    await _typeAndSend(tester, 'take a picture with the front camera');

    expect(find.text('Front camera'), findsNothing); // no choice sheet
    expect(rig.picker.calls, hasLength(1));
    expect(rig.picker.calls.single.device, CameraDevice.front);
  });

  testWidgets(
      'permission denied degrades gracefully: an honest Ayma line, no '
      'capture in the chat, no /chat send', (tester) async {
    final streamBodies = <Map<String, dynamic>>[];
    final rig = await _pumpChat(tester, streamBodies: streamBodies);
    rig.picker.error = PlatformException(
      code: 'camera_access_denied',
      message: 'Camera access denied.',
    );

    await _typeAndSend(tester, 'take a picture');
    await tester.tap(find.text('Front camera'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining("couldn't open the camera"),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    expect(rig.chat.calls, isEmpty);
    expect(streamBodies, isEmpty);
  });

  testWidgets('closing the camera without a shot says no picture was taken',
      (tester) async {
    final streamBodies = <Map<String, dynamic>>[];
    final rig = await _pumpChat(tester, streamBodies: streamBodies);
    rig.picker.returnNull = true;

    await _typeAndSend(tester, 'take a picture');
    await tester.tap(find.text('Back camera'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No picture taken'), findsOneWidget);
    expect(streamBodies, isEmpty);
  });
}
