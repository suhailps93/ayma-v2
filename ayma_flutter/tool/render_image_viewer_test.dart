import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/widgets/image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the fullscreen image viewer fix
/// (founder bug, build 2061: viewer opened as a top strip with the chat
/// visible behind it) — not part of the regular test suite (lives under
/// tool/, which `flutter test` doesn't scan by default). Run explicitly:
///   flutter test tool/render_image_viewer_test.dart
///
/// Unlike the canvas-only sibling tools, this captures the REAL
/// `AymaImageViewer` widget tree at rest — a 1:1 image on a 1080x2364
/// viewport — via a `RepaintBoundary`, which is exactly what the fix is
/// about (route/Stack/fit geometry). The viewer uses no google_fonts text,
/// so the `tester.runAsync` capture is safe; MaterialIcons is loaded from
/// the local Flutter SDK cache so the X/share/save glyphs render for real.
void main() {
  testWidgets('render the fullscreen viewer at rest (1:1 on 1080x2364)',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2364);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1080, 2364));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Real icon glyphs (X / share / download) instead of tofu boxes.
    await tester.runAsync(() async {
      final root = Platform.environment['FLUTTER_ROOT'];
      final otf = File(
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (root != null && otf.existsSync()) {
        final loader = FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.sublistView(otf.readAsBytesSync())));
        await loader.load();
      }
    });

    // A recognizable 1:1 fixture image (gradient + circle), 900x900 px.
    final fixture = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const size = 900.0;
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, size, size),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            const Offset(size, size),
            const [Color(0xFF2C5F8A), Color(0xFFB0603A)],
          ),
      );
      canvas.drawCircle(const Offset(size / 2, size / 2), 260,
          Paint()..color = const Color(0xFFEDE9DE));
      final image = await recorder.endRecording().toImage(900, 900);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory.systemTemp.createTempSync('ayma_viewer_render');
      final f = File('${dir.path}/fixture_900.png');
      await f.writeAsBytes(bytes!.buffer.asUint8List());
      return f;
    });

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      AymaImageViewer.open(context, file: fixture!),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() =>
        precacheImage(FileImage(fixture!), tester.element(find.text('open'))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AymaImageViewer), findsOneWidget);

    final png = await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      return image.toByteData(format: ui.ImageByteFormat.png);
    });
    final out = File('build/image_viewer_preview.png');
    await tester.runAsync(() async {
      await out.parent.create(recursive: true);
      await out.writeAsBytes(png!.buffer.asUint8List());
    });
    // ignore: avoid_print
    print('Wrote ${out.absolute.path}');
  });
}
