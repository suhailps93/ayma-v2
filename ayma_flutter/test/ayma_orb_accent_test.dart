import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _green = Color(0xFF2EAD55);
const _size = 240.0;

Future<ByteData> _render(Color accent) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  AymaOrbPainter(
    t: 0.3,
    fromState: AymaOrbState.speaking,
    toState: AymaOrbState.speaking,
    transitionT: 1,
    amplitude: 0.6,
    accent: accent,
    reducedMotion: false,
    showGlow: true,
    voiceLive: true,
  ).paint(canvas, const Size(_size, _size));
  final image =
      await recorder.endRecording().toImage(_size.toInt(), _size.toInt());
  return (await image.toByteData())!;
}

/// Share of opaque, clearly-coloured pixels whose hue is near Cherry Fuchsia.
double _pinkShare(ByteData data) {
  final pink = HSLColor.fromColor(AymaColors.accent).hue;
  var coloured = 0;
  var pinkish = 0;
  for (var i = 0; i < data.lengthInBytes; i += 4) {
    final c = Color.fromARGB(data.getUint8(i + 3), data.getUint8(i),
        data.getUint8(i + 1), data.getUint8(i + 2));
    if (c.a < 0.5) continue;
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.4 || hsl.lightness < 0.2 || hsl.lightness > 0.85) {
      continue;
    }
    coloured++;
    final d = (hsl.hue - pink).abs();
    if (d < 25 || d > 335) pinkish++;
  }
  return coloured == 0 ? 0 : pinkish / coloured;
}

void main() {
  test('default accent keeps the original ring and petal glow tones', () {
    expect(
        AymaColors.orbGlowTone(AymaColors.accent, AymaColors.orbGlowSphereHot),
        const Color(0xFFFF2A6A));
    expect(AymaColors.orbGlowTone(AymaColors.accent, AymaColors.orbGlowHotPink),
        const Color(0xFFFF3D8C));
  });

  test('ring and petal highlight tones follow the accent hue', () {
    final ring = AymaColors.orbGlowTone(_green, AymaColors.orbGlowSphereHot);
    final petal = AymaColors.orbGlowTone(_green, AymaColors.orbGlowHotPink);
    final greenHue = HSLColor.fromColor(_green).hue;
    for (final c in [ring, petal]) {
      expect((HSLColor.fromColor(c).hue - greenHue).abs(), lessThan(25));
    }
    expect(ring, isNot(AymaColors.orbGlowSphereHot));
    expect(petal, isNot(AymaColors.orbGlowHotPink));
  });

  testWidgets('rendered orb is pink by default but not on a green accent',
      (tester) async {
    final def = (await tester.runAsync(() => _render(AymaColors.accent)))!;
    final green = (await tester.runAsync(() => _render(_green)))!;
    expect(_pinkShare(def), greaterThan(0.5));
    expect(_pinkShare(green), lessThan(0.02));
  });
}
