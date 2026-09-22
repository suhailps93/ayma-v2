import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_rail_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the new action-rail icon glyphs
/// (`ayma_rail_icons.dart`) — not part of the regular test suite (lives
/// under tool/, which `flutter test` doesn't scan by default), same pattern
/// as `generate_app_icon_test.dart`. Run explicitly:
///   flutter test tool/generate_rail_icons_test.dart
///
/// Renders each of the 4 glyphs in both states (8 total) inside a simulated
/// rail-button circle — off-white circle + soft shadow for inactive, accent
/// circle + accent glow for active, matching `_RailButton`'s real treatment
/// — so the PNG shows what actually ends up on screen, not just the bare
/// glyph in isolation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate action-rail glyph PNGs', () async {
    const accent = AymaColors.accent; // Cherry Fuchsia default.
    const cell = 220.0;
    const circleD = 150.0;
    const iconSize = circleD * 0.45;
    const rows = ['heart', 'chat', 'search', 'match'];
    const canvasW = cell * 2;
    final canvasH = cell * rows.length;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasW, canvasH),
      Paint()..color = const Color(0xFF15130F),
    );

    for (var row = 0; row < rows.length; row++) {
      final name = rows[row];
      for (var col = 0; col < 2; col++) {
        final filled = col == 1;
        final cx = col * cell + cell / 2;
        final cy = row * cell + cell / 2;

        canvas.save();
        canvas.translate(cx, cy);
        if (filled) {
          canvas.drawCircle(
            Offset.zero,
            circleD / 2 + 10,
            Paint()
              ..color = accent.withValues(alpha: 0.45)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
          );
        } else {
          canvas.drawCircle(
            Offset.zero,
            circleD / 2 + 6,
            Paint()
              ..color = Colors.black.withValues(alpha: 0.28)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
          );
        }
        canvas.drawCircle(
          Offset.zero,
          circleD / 2,
          Paint()..color = filled ? accent : AymaColors.lightBg,
        );
        canvas.restore();

        canvas.save();
        canvas.translate(cx - iconSize / 2, cy - iconSize / 2);
        _painterFor(name, accent, filled)
            .paint(canvas, const Size(iconSize, iconSize));
        canvas.restore();
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW.round(), canvasH.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('build/rail_icons_preview.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  });
}

CustomPainter _painterFor(String name, Color accent, bool filled) {
  switch (name) {
    case 'heart':
      return AymaHeartGlyph(accent: accent, filled: filled).buildPainter();
    case 'chat':
      return AymaChatGlyph(accent: accent, filled: filled).buildPainter();
    case 'search':
      return AymaSearchGlyph(accent: accent, filled: filled).buildPainter();
    case 'match':
      return AymaMatchGlyph(accent: accent, filled: filled).buildPainter();
    default:
      throw ArgumentError(name);
  }
}
