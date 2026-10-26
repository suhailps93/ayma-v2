// Renders the shareable Appearance report card through the real export path
// (`ReportCardShare.renderPng`, 1080x1920) to a PNG for visual review.
//
//   flutter test tool/render_report_card_test.dart
//
// Output: build/report_card.png and build/report_card_light_accent.png.
// Fonts: the bundled Geist is loaded for real. Instrument Serif and JetBrains
// Mono are google_fonts runtime fonts this sandbox can't fetch, so pass local
// TTFs via REPORT_CARD_SERIF_TTF / REPORT_CARD_MONO_TTF to see the real faces
// (registered under google_fonts' own family names); without them the
// test font stands in.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/appearance_card.dart';
import 'package:ayma_flutter/services/report_card_share.dart';
import 'package:ayma_flutter/widgets/appearance_report_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadFont(String family, String? path) async {
  if (path == null || path.isEmpty || !File(path).existsSync()) return;
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(
    family,
  )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
}

/// A flat-colour 300x400 stand-in photo.
Future<ImageProvider> _photo(Color c) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 300, 400), Paint()..color = c);
  return DecodedImage(await rec.endRecording().toImage(300, 400));
}

void main() {
  testWidgets('render the report card', (tester) async {
    const data = AppearanceCardData(
      pool: [
        CardPhoto(url: 'a', label: 'Your face photo', id: 'a'),
        CardPhoto(url: 'b', label: 'Your body photo', id: 'b'),
        CardPhoto(url: 'c', label: 'Your photo', id: 'c'),
        CardPhoto(url: 'd', label: 'Your photo', id: 'd'),
      ],
      hidden: {},
      faceScore: '6.3',
      faceVerdict: 'Above average',
      bodyScore: '4.2',
      bodyVerdict: 'Below average',
      standOuts: [
        'Full eyebrows',
        'Broad shoulders',
        'Expressive dark eyes',
        'Thick, textured, naturally curly hair that frames the face',
      ],
      nextSteps: [],
    );
    // No network here: google_fonts' own fetches of Instrument Serif and
    // JetBrains Mono fail asynchronously. Those errors are swallowed by this
    // zone (the TTFs loaded below stand in); any other error fails the run.
    await tester.runAsync(() {
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          await _render(tester, data);
          done.complete();
        },
        (e, st) {
          if ('$e'.contains('Failed to load font')) return;
          if (!done.isCompleted) done.completeError(e, st);
        },
      );
      return done.future;
    });
  });
}

Future<void> _render(WidgetTester tester, AppearanceCardData data) async {
  await _loadFont('Geist', 'assets/fonts/Geist-Regular.ttf');
  final env = Platform.environment;
  await _loadFont('InstrumentSerif_regular', env['REPORT_CARD_SERIF_TTF']);
  await _loadFont('JetBrainsMono_500', env['REPORT_CARD_MONO_TTF']);

  final photos = [
    for (final c in const [
      Color(0xFF8D6E63),
      Color(0xFF5C6BC0),
      Color(0xFF26A69A),
      Color(0xFFFFB74D),
    ])
      (await _photo(c), 'photo'),
  ];
  Directory('build').createSync(recursive: true);
  for (final (file, accent) in const [
    ('build/report_card.png', Color(0xFFDA4B65)),
    ('build/report_card_light_accent.png', Color(0xFFFFE066)),
  ]) {
    final png = await ReportCardShare.renderPng(
      AppearanceReportCard(
        data: data,
        name: 'Suhail',
        accent: accent,
        photos: photos,
      ),
      view: tester.view,
      logicalSize: AppearanceReportCard.size,
    );
    File(file).writeAsBytesSync(png);
  }
}
