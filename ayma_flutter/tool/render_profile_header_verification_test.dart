import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the redesigned `ProfilePhotoHeader`
/// layout (founder reference: dark gradient scrim fading up from the photo
/// bottom, serif name + " · age" in white, an "Active now" status row shown
/// only when real, and a bottom photo filmstrip with an accent-ringed
/// selected thumbnail) — not part of the regular test suite (lives under
/// tool/, which `flutter test` doesn't scan by default), same pattern as
/// `render_orb_verification_test.dart`/`generate_rail_icons_test.dart`. Run
/// explicitly:
///   flutter test tool/render_profile_header_verification_test.dart
///
/// Draws the SAME geometry/colours/gradient-stops the real
/// `_ProfilePhotoHeaderState.build` uses via a raw `Canvas`, same as those
/// two sibling scripts — not by pumping the actual widget tree through
/// `WidgetTester`. That's deliberate here, not a shortcut: capturing a
/// `RepaintBoundary` image needs `tester.runAsync` (a real, non-fake-async
/// zone) for `toImage`/`toByteData` to resolve at all, and in that zone
/// `AymaType.serif`/`sans` (google_fonts) also fire their own real
/// network font fetch — which this sandbox has no network for — as an
/// unhandled async error that reliably hangs or fails the test host. Text
/// here uses a plain system serif/sans stand-in instead so the geometry,
/// colours and gradients — everything actually being verified — are an
/// honest capture of what ships; only the exact glyph shapes are a stand-in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Color fallbackTop(String seed) {
    final h1 = (seed.hashCode.abs() % 360).toDouble();
    return HSLColor.fromAHSL(1, h1, 0.28, 0.30).toColor();
  }

  Color fallbackBottom(String seed) {
    final h1 = (seed.hashCode.abs() % 360).toDouble();
    return HSLColor.fromAHSL(1, (h1 + 40) % 360, 0.22, 0.18).toColor();
  }

  Future<void> renderTo(
    String path, {
    required String seed,
    required String name,
    int? age,
    required String location,
    bool isOnline = false,
    int photoCount = 4,
    String? blockedMessage,
    double width = 390,
  }) async {
    const photoSize = 390.0;
    const filmstripH = 72.0;
    final hasFilmstrip = photoCount > 1;
    final blockedH = blockedMessage != null ? 40.0 : 0.0;
    final height = photoSize + (hasFilmstrip ? filmstripH : 0) + blockedH;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Page background (dark theme, matches AymaTheme.darkWithAccent's `bg`).
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = AymaColors.darkBg,
    );

    // Photo (seeded fallback gradient — same formula as `_ProfilePhotoHeader
    // State.build`'s own `fallback`).
    final photoRect = ui.Rect.fromLTWH(0, 0, width, photoSize);
    canvas.drawRect(
      photoRect,
      ui.Paint()
        ..shader = ui.Gradient.linear(
          photoRect.topLeft,
          photoRect.bottomRight,
          [fallbackTop(seed), fallbackBottom(seed)],
        ),
    );

    // Dark gradient scrim fading up from the bottom of the photo — same
    // stops/colours as the real widget's `Positioned.fill` scrim.
    canvas.drawRect(
      photoRect,
      ui.Paint()
        ..shader = ui.Gradient.linear(
          ui.Offset(width / 2, 0),
          ui.Offset(width / 2, photoSize),
          [Colors.transparent, Colors.black.withValues(alpha: 0.9)],
          [0.45, 1.0],
        ),
    );

    // Name + " · age" — plain serif/sans stand-ins (see file doc: avoids
    // google_fonts' real network fetch, which this sandbox can't make).
    final textLeft = 20.0;
    var y = photoSize - 16;
    final ageSpan = age != null
        ? TextSpan(
            text: ' · $age',
            style: const TextStyle(
                fontFamily: 'serif', fontSize: 16, color: Colors.white70),
          )
        : null;
    final nameSpan = TextSpan(
      text: name.isEmpty ? 'Someone' : name,
      style: const TextStyle(
          fontFamily: 'serif', fontSize: 28, color: Colors.white),
      children: ageSpan != null ? [ageSpan] : null,
    );
    final namePainter = TextPainter(
      text: nameSpan,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - textLeft - 20);
    y -= namePainter.height;
    namePainter.paint(canvas, ui.Offset(textLeft, y));

    // Status row: green dot + "Active now" · location, or just location.
    if (isOnline || location.isNotEmpty) {
      final statusText = StringBuffer();
      if (isOnline) {
        statusText.write('Active now');
        if (location.isNotEmpty) statusText.write('  ·  ');
      }
      statusText.write(location);
      final statusPainter = TextPainter(
        text: TextSpan(
          text: statusText.toString(),
          style: const TextStyle(
              fontFamily: 'sans-serif', fontSize: 13, color: Colors.white70),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - textLeft - 20 - (isOnline ? 14 : 0));
      final statusY = y - 6 - statusPainter.height;
      var dotOffset = 0.0;
      if (isOnline) {
        canvas.drawCircle(
          ui.Offset(textLeft + 4, statusY + statusPainter.height / 2),
          4,
          ui.Paint()..color = AymaColors.success,
        );
        dotOffset = 14;
      }
      statusPainter.paint(canvas, ui.Offset(textLeft + dotOffset, statusY));
    }

    // Bottom filmstrip — solid dark strip, rounded-square thumbnails, the
    // "selected" (first) one ringed in the live accent colour.
    if (hasFilmstrip) {
      final stripRect = ui.Rect.fromLTWH(0, photoSize, width, filmstripH);
      canvas.drawRect(stripRect, ui.Paint()..color = AymaColors.darkBg);
      const thumb = 52.0;
      const gap = 8.0;
      var x = 12.0;
      for (var i = 0; i < photoCount; i++) {
        final r = ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(x, photoSize + 10, thumb, thumb),
          const ui.Radius.circular(9),
        );
        canvas.drawRRect(
          r.deflate(1),
          ui.Paint()..color = fallbackTop('$seed-$i'),
        );
        if (i == 0) {
          canvas.drawRRect(
            r,
            ui.Paint()
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = AymaColors.accent,
          );
        }
        x += thumb + gap;
      }
    }

    // Blocked-message note, below the filmstrip.
    if (blockedMessage != null) {
      final msgPainter = TextPainter(
        text: TextSpan(
          text: blockedMessage,
          style: const TextStyle(
              fontFamily: 'sans-serif', fontSize: 13, color: AymaColors.error),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width - 40);
      msgPainter.paint(
        canvas,
        ui.Offset(20, photoSize + (hasFilmstrip ? filmstripH : 0) + 12),
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.round(), height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote $path (${bytes.lengthInBytes} bytes)');
  }

  test('render header — online, multiple photos (founder reference case)',
      () async {
    await renderTo(
      '/tmp/ayma_profile_header_verify/online_with_filmstrip.png',
      seed: 'ella',
      name: 'Ella',
      age: 32,
      location: 'Brooklyn, NY',
      isOnline: true,
      photoCount: 6,
    );
  });

  test('render header — offline (no status dot), single photo (no filmstrip)',
      () async {
    await renderTo(
      '/tmp/ayma_profile_header_verify/offline_single_photo.png',
      seed: 'sam',
      name: 'Samantha',
      age: 29,
      location: 'Austin, TX',
      photoCount: 1,
    );
  });

  test('render header — blocked message', () async {
    await renderTo(
      '/tmp/ayma_profile_header_verify/blocked.png',
      seed: 'x',
      name: 'X',
      age: 40,
      location: 'Unknown',
      photoCount: 2,
      blockedMessage: "You've blocked this person.",
    );
  });
}
