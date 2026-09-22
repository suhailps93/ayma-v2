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
/// Renders each of the 4 glyphs in both states (8 total) — no circle/disc
/// background behind either state (founder spec, 2026-09-22 revision): the
/// "not done" state is a thin outline glyph, the "done" state is a solid
/// filled glyph with its own glow hugging its silhouette (painted by the
/// glyph's own painter — see `ayma_rail_icons.dart`'s `_glowPath`/
/// `_glowCircle`/`_glowLine`), matching `_RailButton`'s real treatment —
/// so the PNG shows what actually ends up on screen, not just the bare
/// glyph in isolation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate action-rail glyph PNGs', () async {
    const accent = AymaColors.accent; // Cherry Fuchsia default.
    const cell = 220.0;
    // Matches `_RailButton`'s real 42px-in-64px ratio (icon doubled from 21
    // to 42, founder ask 2026-09-22 — "double the icon size, remove the text
    // below") roughly, scaled up for a legible preview.
    const iconSize = cell * 0.68;
    const rows = ['heart', 'chat', 'search', 'match'];
    const canvasW = cell * 2;
    final canvasH = cell * rows.length;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // A busy-photo stand-in (mid-tone, not flat black/white) so legibility
    // of the glyph-only (no disc) treatment is actually being tested.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasW, canvasH),
      Paint()..color = const Color(0xFF5B5148),
    );

    for (var row = 0; row < rows.length; row++) {
      final name = rows[row];
      for (var col = 0; col < 2; col++) {
        final filled = col == 1;
        final cx = col * cell + cell / 2;
        final cy = row * cell + cell / 2;

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
