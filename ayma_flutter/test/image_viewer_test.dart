import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:ayma_flutter/widgets/image_viewer.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// A tiny, real, checked-in PNG — Flutter's image codec needs decodable
/// bytes to render `Image.file` without erroring.
const _fixturePath = 'test/fixtures/tiny.png';

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

/// Upload that never resolves — keeps the optimistic turn on its local file
/// so the viewer exercises the `Image.file` path with no network.
class _StuckChatService extends ChatService {
  final uploadGate = Completer<ChatImageUpload>();

  @override
  Future<ChatImageUpload> uploadChatImage(File file) => uploadGate.future;
}

Future<void> _pumpViewer(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              AymaImageViewer.open(context, file: File(_fixturePath)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('viewer shows the image with share, save and close actions',
      (tester) async {
    await _pumpViewer(tester);

    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is FileImage),
      findsOneWidget,
    );
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('X dismisses the viewer back to the underlying screen',
      (tester) async {
    await _pumpViewer(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.share_outlined), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('swiping down dismisses the viewer', (tester) async {
    await _pumpViewer(tester);

    await tester.fling(
        find.byType(InteractiveViewer), const Offset(0, 400), 1200);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.share_outlined), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('tapping a chat transcript photo opens the full-screen viewer',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: _jsonUtf8);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api = ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        chatService: _StuckChatService(),
        imagePicker: _FakeImagePicker(_fixturePath),
      ),
    ));
    await tester.pumpAndSettle();

    // Attach the fixture photo and send — the optimistic turn renders it
    // straight from the local file while the (never-finishing) upload runs.
    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    final photo =
        find.byWidgetPredicate((w) => w is Image && w.image is FileImage);
    expect(photo, findsOneWidget);

    // The 1x1 fixture lays out too small for a coordinate tap — fire the
    // thumbnail's tap handler directly (same wiring, no hit-test flake).
    final tappable = tester.widget<GestureDetector>(
      find
          .ancestor(of: photo, matching: find.byType(GestureDetector))
          .first,
    );
    expect(tappable.onTap, isNotNull);
    tappable.onTap!();
    await tester.pumpAndSettle();

    // Full-screen viewer with its share/save/close chrome.
    expect(find.byType(AymaImageViewer), findsOneWidget);
    expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);

    // Dismiss returns to the transcript.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(AymaImageViewer), findsNothing);
    expect(photo, findsOneWidget);
  });
}
