import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:flutter_test/flutter_test.dart';

import 'baseline/head_orb_painter.dart';

/// Offline, deterministic `AymaOrbPainter.paint()` cost benchmark — the
/// evidence half of the 2026-09-27 "the app is still slow" paint pass.
///
/// For each (state, size) it drives BOTH painters — `HeadAymaOrbPainter`
/// (the vendored pre-optimization copy, see `tool/baseline/`) and the live
/// `AymaOrbPainter` — through the same frame sequence (`t` advancing at
/// 60fps, exactly what a fluttering orb replays on device) and reports
/// µs/frame twice per painter:
///
///  * record — building the display list (`paint()` into a
///    `PictureRecorder` canvas): the UI-thread cost every repaint pays,
///    where shader/path/allocation work lands;
///  * raster — `Picture.toImage`, Skia software rasterization: where the
///    blurred strokes and gradients actually burn pixels (identical draw
///    ops before/after, so this column mostly proves no regression).
///
/// Not part of the regular suite — run explicitly:
///   flutter test tool/bench_orb_paint_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const recordFrames = 400;
  const rasterFrames = 24;

  CustomPainter head({
    required AymaOrbState state,
    required double t,
    required double amplitude,
    required bool voiceLive,
  }) =>
      HeadAymaOrbPainter(
        t: t,
        fromState: state,
        toState: state,
        transitionT: 1,
        amplitude: amplitude,
        accent: AymaColors.accent,
        reducedMotion: false,
        showGlow: true,
        voiceLive: voiceLive,
      );

  CustomPainter current({
    required AymaOrbState state,
    required double t,
    required double amplitude,
    required bool voiceLive,
  }) =>
      AymaOrbPainter(
        t: t,
        fromState: state,
        toState: state,
        transitionT: 1,
        amplitude: amplitude,
        accent: AymaColors.accent,
        reducedMotion: false,
        showGlow: true,
        voiceLive: voiceLive,
      );

  test('benchmark paint() µs/frame, HEAD vs optimized', () async {
    final cases = <(String, AymaOrbState, double, bool)>[
      ('idle', AymaOrbState.idle, 0.0, false),
      ('thinking', AymaOrbState.thinking, 0.0, false),
      ('listening', AymaOrbState.listening, 0.6, false),
      ('speaking', AymaOrbState.speaking, 0.6, false),
      ('listening live', AymaOrbState.listening, 0.6, true),
      ('speaking live', AymaOrbState.speaking, 0.6, true),
    ];
    final sizes = <double>[64, 400];

    // µs/frame keyed "case|size|variant" -> (record, raster). Variants are
    // interleaved (head, opt, head, opt, ...) and each takes the MIN over
    // the repetitions — the standard microbenchmark defence against JIT
    // warm-up drift and GC noise in the test VM. Record (the UI-thread cost
    // this pass attacks) gets more reps than raster (identical draw ops
    // before/after; the column exists to prove no regression).
    const recordReps = 6;
    const rasterReps = 2;
    final results = <String, (double, double)>{};

    for (final (name, state, amp, live) in cases) {
      for (final size in sizes) {
        final sz = ui.Size(size, size);
        final px = size.round();

        for (final (variant, make) in [('head', head), ('opt', current)]) {
          void record(int frames, {List<ui.Picture>? out}) {
            for (var i = 0; i < frames; i++) {
              final recorder = ui.PictureRecorder();
              final canvas = ui.Canvas(recorder);
              make(
                state: state,
                t: i / 60.0,
                amplitude: amp,
                voiceLive: live,
              ).paint(canvas, sz);
              final picture = recorder.endRecording();
              if (out != null) {
                out.add(picture);
              } else {
                picture.dispose();
              }
            }
          }

          // Warm-up (JIT + caches), untimed.
          record(120);

          final sw = Stopwatch();
          var recordUs = double.infinity;
          var rasterUs = double.infinity;
          for (var rep = 0; rep < recordReps; rep++) {
            sw
              ..reset()
              ..start();
            record(recordFrames);
            sw.stop();
            recordUs = math.min(
                recordUs, sw.elapsedMicroseconds / recordFrames);
          }
          for (var rep = 0; rep < rasterReps; rep++) {
            // Raster: record untimed, rasterize timed.
            final pics = <ui.Picture>[];
            record(rasterFrames, out: pics);
            (await pics.first.toImage(px, px)).dispose(); // raster warm-up
            sw
              ..reset()
              ..start();
            for (final pic in pics) {
              (await pic.toImage(px, px)).dispose();
            }
            sw.stop();
            for (final pic in pics) {
              pic.dispose();
            }
            rasterUs = math.min(
                rasterUs, sw.elapsedMicroseconds / rasterFrames);
          }

          results['$name|$px|$variant'] = (recordUs, rasterUs);
        }
      }
    }

    final buf = StringBuffer()
      ..writeln('')
      ..writeln('AymaOrbPainter.paint() µs/frame — HEAD (before) vs '
          'optimized (after), $recordFrames record / $rasterFrames raster '
          'frames each:')
      ..writeln('')
      ..writeln('| state | px | record before | record after | raster before '
          '| raster after |')
      ..writeln('|---|---|---|---|---|---|');
    for (final (name, _, _, _) in cases) {
      for (final size in sizes) {
        final px = size.round();
        final (rb, sb) = results['$name|$px|head']!;
        final (ra, sa) = results['$name|$px|opt']!;
        buf.writeln('| $name | $px | ${rb.toStringAsFixed(1)} | '
            '${ra.toStringAsFixed(1)} | ${sb.toStringAsFixed(1)} | '
            '${sa.toStringAsFixed(1)} |');
      }
    }
    // ignore: avoid_print
    print(buf);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
