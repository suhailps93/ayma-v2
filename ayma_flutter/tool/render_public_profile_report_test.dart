import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the converged public-profile Living
/// Report (§ founder, 2026-09-27: another member's profile content renders
/// through the shared `LivingReportView`, whose BODY prose is now the app's
/// standard sans (Geist) body style — `AymaType.sans(size: 14, height:
/// 1.5)`, the exact style the old bespoke `PublicProfileBody` used — while
/// the report title stays serif and section headings stay the mono eyebrow).
///
/// Not part of the regular test suite (lives under tool/, which
/// `flutter test` doesn't scan by default) — same pattern as
/// `render_profile_header_verification_test.dart`. Run explicitly:
///   flutter test tool/render_public_profile_report_test.dart
///
/// A pure-canvas render, not a mounted widget tree, for the same reason
/// that sibling documents: capturing a `RepaintBoundary` needs
/// `tester.runAsync`, in which `AymaType.serif`/`mono` (google_fonts) fire
/// a real network font fetch this sandbox can't make. The BODY text is the
/// thing under verification here, and Geist is bundled locally
/// (`assets/fonts/`), so it's loaded for real via [FontLoader] — the body
/// glyphs in the output are the actual shipped font at the actual
/// `_bodyStyle` metrics (Geist 14 / height 1.5). The serif title and mono
/// headings use locally-available stand-in FACES (DejaVu Serif / Ubuntu
/// Mono, loaded the same way — a bare system family name like 'serif'
/// renders as Ahem boxes in the flutter_test environment), at their real
/// sizes, so the serif-vs-mono-vs-sans contrast is honestly visible even
/// though those two exact glyph designs are stand-ins.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  test('render a sample public-profile Living Report page', () async {
    // The real bundled Geist face, so the body render is the shipped font.
    await loadFont('Geist', 'assets/fonts/Geist-Regular.ttf');
    // Stand-in faces for the serif/mono roles (see file doc).
    await loadFont(
        'StandinSerif', '/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf');
    await loadFont(
        'StandinMono', '/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf');

    const width = 420.0;
    const pad = 20.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    const bg = AymaColors.darkBg;
    const fg = AymaColors.darkFg;
    const accent = AymaColors.accent;

    // --- the sample content: a profile page's sections, exactly the shape
    // `report_adapters.public_profile_blocks` emits (heading + flowing
    // sentence prose), rendered with `LivingReportView`'s own three
    // typography roles.
    const sections = <(String, String)>[
      (
        'IDENTITY',
        'Dana grew up between Lisbon and Porto and moved to Berlin for a '
            'design residency that turned into a decade. She speaks three '
            'languages and swears her Portuguese is the funniest of them.',
      ),
      (
        'WORK & STUDY',
        'She leads a small product team at a mapping startup. Before that, '
            'four years of freelance illustration — she still takes one '
            'commission a year, purely to stay honest.',
      ),
      (
        'INTERESTS',
        'Climbs three mornings a week and cooks like it is a competitive '
            'sport. Currently obsessed with fermentation and with finding '
            'the city\'s best natural wine below ten euros.',
      ),
    ];

    // Styles — the REAL body role (`_bodyStyle`: Geist 14 / 1.5), and the
    // title/heading roles at their real sizes with stand-in families (see
    // file doc).
    final bodyStyle = AymaType.sans(size: 14, color: fg, height: 1.5);
    const titleStyle = TextStyle(
        fontFamily: 'StandinSerif', fontSize: 24, color: fg, height: 1.15);
    const headingStyle = TextStyle(
        fontFamily: 'StandinMono',
        fontSize: 15,
        letterSpacing: 1.8,
        fontWeight: FontWeight.w500,
        color: accent);

    TextPainter tp(String text, TextStyle style) => TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width - pad * 2);

    // Lay out first (height depends on content), then paint bg + text.
    final ops = <void Function(Canvas)>[];
    var y = 16.0;

    // Report title (serif role — `_titleStyle`, size 24). On the real
    // screen `showTitle` is false (the name already heads the screen), but
    // it's rendered here so the serif-vs-sans contrast is verifiable in
    // one image.
    final title = tp('Dana', titleStyle);
    final ty = y;
    ops.add((c) => title.paint(c, const Offset(pad, 16)));
    y = ty + title.height + 24;

    for (final (heading, body) in sections) {
      final h = tp(heading, headingStyle);
      final hy = y;
      ops.add((c) => h.paint(c, Offset(pad, hy)));
      y += h.height + 12;
      final b = tp(body, bodyStyle);
      final by = y;
      ops.add((c) => b.paint(c, Offset(pad, by)));
      y += b.height + 28;
    }
    final height = y + 12;

    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = bg);
    for (final op in ops) {
      op(canvas);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.round(), height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('build/public_profile_report_preview.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  });
}
