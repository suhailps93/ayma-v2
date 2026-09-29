import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:ayma_flutter/widgets/ayma_chat_modal.dart';
import 'package:ayma_flutter/widgets/image_viewer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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
  }) async => XFile(path);
}

/// Upload that never resolves — keeps the optimistic turn on its local file
/// so the viewer exercises the `Image.file` path with no network.
class _StuckChatService extends ChatService {
  final uploadGate = Completer<ChatImageUpload>();

  @override
  Future<ChatImageUpload> uploadChatImage(File file) => uploadGate.future;
}

/// Serves one local fixture file for any URL — the viewer's real
/// network-image pipeline (CachedNetworkImageProvider → decode → RawImage)
/// runs against it with no platform channels or network.
class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
    : file = const LocalFileSystem().file(ioFile.path);
  // flutter_cache_manager's API speaks package:file's File type.
  final fs.File file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async => file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Writes a real decodable PNG of the given pixel size to a temp file.
Future<File> _pngFixture(WidgetTester tester, int width, int height) async {
  final file = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF3B6EA5),
    );
    final image = await recorder.endRecording().toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory.systemTemp.createTempSync('ayma_viewer_test');
    final f = File('${dir.path}/fixture_${width}x$height.png');
    await f.writeAsBytes(bytes!.buffer.asUint8List());
    return f;
  });
  return file!;
}

/// The founder-bug assertions: the viewer route must be a truly fullscreen,
/// OPAQUE ground (nothing of the chat paints through), and the image at rest
/// must sit centered, contain-fit to the viewport — covering (nearly) all of
/// at least one axis, whatever the source resolution.
void _expectFullscreenCenteredViewer(WidgetTester tester, Size viewport) {
  final viewer = find.byType(AymaImageViewer);
  expect(viewer, findsOneWidget);

  // Truly fullscreen, opaque route: solid ground over the whole screen.
  final route = ModalRoute.of(tester.element(viewer))!;
  expect(
    route.opaque,
    isTrue,
    reason:
        'viewer route must be opaque — the chat must not stay '
        'visible behind the image',
  );
  expect(
    tester.getRect(viewer),
    Offset.zero & viewport,
    reason: 'viewer must fill the whole screen',
  );
  final scaffold = tester.widget<Scaffold>(
    find.descendant(of: viewer, matching: find.byType(Scaffold)),
  );
  expect(
    scaffold.backgroundColor,
    Colors.black,
    reason: 'viewer ground must be solid black',
  );

  // The decoded image paints centered and contain-fit to the viewport.
  final rawFinder = find.descendant(
    of: viewer,
    matching: find.byWidgetPredicate((w) => w is RawImage && w.image != null),
  );
  expect(
    rawFinder,
    findsOneWidget,
    reason: 'the viewer must show the decoded image',
  );
  final raw = tester.widget<RawImage>(rawFinder);
  final box = tester.getRect(rawFinder);
  final intrinsic = Size(
    raw.image!.width.toDouble(),
    raw.image!.height.toDouble(),
  );
  final fitted = applyBoxFit(raw.fit ?? BoxFit.scaleDown, intrinsic, box.size);
  final alignment = raw.alignment.resolve(TextDirection.ltr);
  final painted = alignment.inscribe(fitted.destination, box);

  final screenCenter = viewport.center(Offset.zero);
  expect(
    (painted.center - screenCenter).distance,
    lessThan(1.5),
    reason:
        'image must be centered in the viewport '
        '(painted rect: $painted)',
  );
  final coverage = math.max(
    painted.width / viewport.width,
    painted.height / viewport.height,
  );
  expect(
    coverage,
    greaterThanOrEqualTo(0.9),
    reason:
        'image must contain-fit the viewport — cover at least 90% of '
        'one axis (painted rect: $painted, viewport: $viewport)',
  );

  // Controls float over the black ground: X top-left, share/save top-right.
  final close = tester.getRect(
    find.descendant(of: viewer, matching: find.byIcon(Icons.close)),
  );
  expect(close.top, lessThan(150));
  expect(close.left, lessThan(viewport.width / 4));
  final save = tester.getRect(
    find.descendant(of: viewer, matching: find.byIcon(Icons.download_outlined)),
  );
  expect(save.top, lessThan(150));
  expect(save.right, greaterThan(viewport.width * 3 / 4));
}

Future<void> _pumpViewer(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                AymaImageViewer.open(context, file: File(_fixturePath)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('viewer shows the image with share, save and close actions', (
    tester,
  ) async {
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

  testWidgets('X dismisses the viewer back to the underlying screen', (
    tester,
  ) async {
    await _pumpViewer(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.share_outlined), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('swiping down dismisses the viewer', (tester) async {
    await _pumpViewer(tester);

    await tester.fling(
      find.byType(InteractiveViewer),
      const Offset(0, 400),
      1200,
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.share_outlined), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('tapping a chat transcript photo opens the full-screen viewer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          apiClient: api,
          chatService: _StuckChatService(),
          imagePicker: _FakeImagePicker(_fixturePath),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Attach the fixture photo and send — the optimistic turn renders it
    // straight from the local file while the (never-finishing) upload runs.
    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    final photo = find.byWidgetPredicate(
      (w) => w is Image && w.image is FileImage,
    );
    expect(photo, findsOneWidget);

    // The 1x1 fixture lays out too small for a coordinate tap — fire the
    // thumbnail's tap handler directly (same wiring, no hit-test flake).
    final tappable = tester.widget<GestureDetector>(
      find.ancestor(of: photo, matching: find.byType(GestureDetector)).first,
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

  // ---- founder bug, build 2061: tapping a chat image opened the viewer as
  // a mess — image a small strip at the top, chat transcript/composer still
  // visible behind it, controls floating over both. These tests host the
  // viewer exactly as production opens it (from the chat popup modal and
  // from a plain screen) and assert the route is opaque + fullscreen and
  // the image paints centered, contain-fit to the viewport.

  const viewport = Size(1080, 2400);
  const generatedUrl =
      'https://firebasestorage.googleapis.com/v0/b/x/o/'
      'ayma_generated%2Fu1%2Ftree.png?alt=media&token=t1';

  for (final (label, w, h) in [('1:1', 300, 300), ('9:16', 270, 480)]) {
    testWidgets('from the chat popup modal, a $label network image opens truly '
        'fullscreen: opaque black, centered, contain-fit', (tester) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fixture = await _pngFixture(tester, w, h);
      AymaImageViewer.debugCacheManager = _FakeCacheManager(fixture);
      addTearDown(() => AymaImageViewer.debugCacheManager = null);

      final mockHttp = MockClient((request) async {
        if (request.url.path == '/chat/history') {
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'role': 'ayma',
                  'text': 'Here is your image',
                  'image_path': 'ayma_generated/u1/tree.png',
                  'image_url': generatedUrl,
                  'created_at': '2026-09-27T18:10:05+00:00',
                },
              ],
              'next_before': null,
            }),
            200,
            headers: _jsonUtf8,
          );
        }
        return http.Response('{}', 200, headers: _jsonUtf8);
      });
      final api = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
      );

      // Host exactly like production: the chat screen embedded in the
      // dockable popup modal (showAymaChatModal), opened over a page.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showAymaChatModal(
                    context,
                    builder: (_) => ChatScreen(apiClient: api),
                  ),
                  child: const Text('ask ayma'),
                ),
              ),
            ),
          ),
        ),
      );

      // Decode the viewer's network image for real (fake cache manager →
      // fixture file) so the pumped tree holds actual pixels.
      await tester.runAsync(
        () => precacheImage(
          CachedNetworkImageProvider(
            generatedUrl,
            cacheManager: AymaImageViewer.debugCacheManager,
          ),
          tester.element(find.text('ask ayma')),
        ),
      );

      await tester.tap(find.text('ask ayma'));
      await tester.pumpAndSettle();
      expect(find.text('Here is your image'), findsOneWidget);

      // Tap the transcript thumbnail (fire its handler directly — the
      // thumbnail's error/placeholder box can lay out too small for a
      // coordinate tap in tests; same wiring either way).
      final thumbTap = tester.widget<GestureDetector>(
        find
            .ancestor(
              of: find.byType(CachedNetworkImage).last,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(thumbTap.onTap, isNotNull);
      thumbTap.onTap!();
      await tester.pumpAndSettle();

      _expectFullscreenCenteredViewer(tester, viewport);

      // The chat behind must NOT stay visible: the opaque viewer route
      // takes the modal and its transcript off-stage entirely.
      expect(
        find.text('Here is your image'),
        findsNothing,
        reason:
            'chat transcript must not remain visible behind the '
            'fullscreen viewer',
      );

      // X closes the viewer only — back to the still-open chat popup.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(AymaImageViewer), findsNothing);
      expect(find.text('Here is your image'), findsOneWidget);
    });

    testWidgets('from the main shell, a $label local-file image opens truly '
        'fullscreen: opaque black, centered, contain-fit', (tester) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fixture = await _pngFixture(tester, w, h);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => AymaImageViewer.open(context, file: fixture),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          FileImage(fixture),
          tester.element(find.text('open')),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      _expectFullscreenCenteredViewer(tester, viewport);
      expect(
        find.text('open'),
        findsNothing,
        reason:
            'the underlying screen must not remain visible behind '
            'the fullscreen viewer',
      );
    });
  }
}
