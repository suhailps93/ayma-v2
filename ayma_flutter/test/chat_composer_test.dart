import 'dart:math' as math;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in [ComposerMode.text]) {
    testWidgets('text composer suppresses inherited fill and focused border', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final level = ValueNotifier<double>(1);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: const [AymaTokens.light],
            inputDecorationTheme: const InputDecorationTheme(
              filled: true,
              fillColor: AymaColors.lightBgElev,
              focusedBorder: OutlineInputBorder(),
            ),
          ),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('composer'),
                child: SizedBox(
                  width: 390,
                  height: 56,
                  child: ChatComposer(
                    mode: mode,
                    controller: controller,
                    focusNode: focus,
                    canSend: true,
                    onSend: () {},
                    onAttach: () {},
                    onMicPressed: () {},
                    onStopPressed: () {},
                    onMuteTap: () {},
                    muted: false,
                    userAmplitude: level,
                    aiAmplitude: level,
                    statusLabel: mode == ComposerMode.listening
                        ? 'Listening…'
                        : 'Ayma is speaking…',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 45; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (mode == ComposerMode.text) {
        // Exercise the actual filled app theme, including keyboard focus.
        await tester.tap(find.byType(TextField));
        await tester.pump(const Duration(milliseconds: 300));
        final decorator = tester.widget<InputDecorator>(
          find.byType(InputDecorator),
        );
        expect(decorator.decoration.filled, false);
        expect(decorator.decoration.focusedBorder, InputBorder.none);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
      level.dispose();
    });
  }

  for (final mode in [ComposerMode.listening, ComposerMode.aiSpeaking]) {
    testWidgets('voice composer wave renders without error as amplitude changes ($mode)', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final level = ValueNotifier<double>(0);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [AymaTokens.light]),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: 56,
                child: ChatComposer(
                  mode: mode,
                  controller: controller,
                  focusNode: focus,
                  canSend: false,
                  onSend: () {},
                  onAttach: () {},
                  onMicPressed: () {},
                  onStopPressed: () {},
                  onMuteTap: () {},
                  muted: false,
                  userAmplitude: level,
                  aiAmplitude: level,
                  statusLabel: mode == ComposerMode.listening
                      ? 'Listening…'
                      : 'Ayma is speaking…',
                ),
              ),
            ),
          ),
        ),
      );
      // Ramp the level up and down like a real conversation would, driving
      // both the eased envelope and the sample buffer through several ticks.
      for (var frame = 0; frame < 60; frame++) {
        level.value = 0.5 + 0.5 * math.sin(frame / 6);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
      level.dispose();
    });
  }

  group('AmplitudeWaveBuffer', () {
    test(
      'produces different sample content across pushes at a constant '
      'input level (real variation, not a resized fixed shape)',
      () {
        final buffer = AmplitudeWaveBuffer(16, random: math.Random(7));
        for (var i = 0; i < 16; i++) {
          buffer.push(0.8);
        }
        final snapshotA = List<double>.from(buffer.samples);
        for (var i = 0; i < 16; i++) {
          buffer.push(0.8);
        }
        final snapshotB = List<double>.from(buffer.samples);
        expect(snapshotA, isNot(equals(snapshotB)));
      },
    );

    test(
      'trends higher for a loud input and lower for a quiet one, without '
      'snapping instantly',
      () {
        final buffer = AmplitudeWaveBuffer(8, random: math.Random(3));
        for (var i = 0; i < 12; i++) {
          buffer.push(1.0);
        }
        final loudMean =
            buffer.samples.reduce((a, b) => a + b) / buffer.length;
        expect(loudMean, greaterThan(0.7));

        // The very next sample after a sudden drop to silence should not
        // have snapped straight to (near) zero — some smoothing remains.
        buffer.push(0.0);
        expect(buffer.samples.last, greaterThan(0.15));

        for (var i = 0; i < 12; i++) {
          buffer.push(0.0);
        }
        final quietMean =
            buffer.samples.reduce((a, b) => a + b) / buffer.length;
        expect(quietMean, lessThan(0.3));
      },
    );

    test('keeps every sample within a bounded, non-noisy range', () {
      final buffer = AmplitudeWaveBuffer(20, random: math.Random(11));
      for (var i = 0; i < 40; i++) {
        buffer.push(1.0);
        expect(buffer.samples.last, inInclusiveRange(0.0, 1.15));
      }
    });
  });

  group('waveEnvelope', () {
    test('tapers to zero at both window edges and peaks at the middle', () {
      expect(waveEnvelope(0.0), 0.0);
      expect(waveEnvelope(1.0), closeTo(0.0, 1e-9));
      expect(waveEnvelope(0.5), 1.0);
    });
  });

  group('clampWaveDisplacement', () {
    test('never lets a wave crest pass the composer half-height', () {
      const composerHeight = 56.0;
      expect(
        clampWaveDisplacement(1000, composerHeight),
        lessThanOrEqualTo(composerHeight / 2),
      );
      expect(clampWaveDisplacement(0, composerHeight), 0);
      // A modest, in-bounds value is passed through unclamped.
      expect(clampWaveDisplacement(10, composerHeight), 10);
    });
  });
}
