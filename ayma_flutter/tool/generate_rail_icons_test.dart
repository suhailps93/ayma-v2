import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_rail_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the action-rail icon family
/// (`ayma_rail_icons.dart`, 2026-09-26 outline→filled redesign) — not part
/// of the regular test suite (lives under tool/, which `flutter test`
/// doesn't scan by default), same pattern as `generate_app_icon_test.dart`.
/// Run explicitly:
///   flutter test tool/generate_rail_icons_test.dart
///
/// Renders the whole vertical rail (Like / Message / Web search / Match,
/// top→bottom, the real order and relative spacing of `_Actions`) on a dark
/// profile-photo-style background, once per required review scenario
/// (founder spec):
///   build/rail_icons_v2/rail_inactive.png   — all four outline
///   build/rail_icons_v2/rail_mixed.png      — Like + Search filled,
///                                             Message + Match outline
///   build/rail_icons_v2/rail_completed.png  — all four filled
///
/// Each glyph is rasterized at 4x the rail's real 32px artwork size (128px
/// cells) so stroke weight, optical size, alignment and glow consistency are
/// actually inspectable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate action-rail scenario PNGs', () async {
    const accent = AymaColors.accent; // Cherry Fuchsia default.
    const scale = 4.0;
    const icon = 32.0 * scale; // the rail's real artwork size, at 4x
    const gapY = 28.0 * scale; // ~ the rail's real inter-icon rhythm
    const padX = 44.0 * scale / 4;
    const padY = 24.0 * scale / 2;

    // Top→bottom, the rail's real order.
    const order = ['heart', 'chat', 'search', 'match'];
    const scenarios = <String, List<bool>>{
      // heart,  chat,   search, match
      'rail_inactive': [false, false, false, false],
      'rail_mixed': [true, false, true, false],
      'rail_completed': [true, true, true, true],
    };

    final canvasW = icon + padX * 2;
    final canvasH = icon * order.length + gapY * (order.length - 1) + padY * 2;

    final outDir = Directory('build/rail_icons_v2');
    await outDir.create(recursive: true);

    for (final entry in scenarios.entries) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // Dark profile-screen stand-in: the photo header's bottom scrim over a
      // dim photo-ish tone, darkening toward the bottom the way the real
      // screen does — so legibility of both states is tested against what
      // the rail actually floats over.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, canvasW, canvasH),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF4A4440), Color(0xFF17141A)],
          ).createShader(Rect.fromLTWH(0, 0, canvasW, canvasH)),
      );

      for (var i = 0; i < order.length; i++) {
        final filled = entry.value[i];
        final top = padY + i * (icon + gapY);
        canvas.save();
        canvas.translate(padX, top);
        _painterFor(order[i], accent, filled)
            .paint(canvas, const Size(icon, icon));
        canvas.restore();
      }

      final picture = recorder.endRecording();
      final image = await picture.toImage(canvasW.round(), canvasH.round());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);

      final file = File('${outDir.path}/${entry.key}.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('Wrote ${file.absolute.path} (${bytes.lengthInBytes} bytes)');
    }
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
