import 'dart:math' as math;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_logo_loader.dart';
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

  group('connecting composer', () {
    Future<void> pumpComposer(
      WidgetTester tester, {
      required ComposerMode mode,
      required String statusLabel,
      bool reduceMotion = false,
    }) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final level = ValueNotifier<double>(0);
      addTearDown(() {
        controller.dispose();
        focus.dispose();
        level.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [AymaTokens.light]),
          home: Scaffold(
            body: Center(
              child: MediaQuery(
                data: MediaQueryData(disableAnimations: reduceMotion),
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
                    statusLabel: statusLabel,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets(
      'shows the animated logo loader and the connecting label, never the '
      'live mic',
      (tester) async {
        await pumpComposer(
          tester,
          mode: ComposerMode.connecting,
          statusLabel: 'Connecting…',
        );
        expect(find.text('Connecting…'), findsOneWidget);
        expect(find.byType(AymaLogoLoader), findsOneWidget);
        // The lit "capturing" mic (listening) must not be shown while
        // connecting — that is exactly what read as "Listening" too early.
        expect(find.byIcon(Icons.mic_rounded), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('waking reuses the same connecting mode and label', (
      tester,
    ) async {
      await pumpComposer(
        tester,
        mode: ComposerMode.connecting,
        statusLabel: 'Waking Ayma…',
      );
      expect(find.text('Waking Ayma…'), findsOneWidget);
      expect(find.byType(AymaLogoLoader), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsNothing);
    });

    testWidgets('reduced motion shows the static (unanimated) logo loader', (
      tester,
    ) async {
      await pumpComposer(
        tester,
        mode: ComposerMode.connecting,
        statusLabel: 'Connecting…',
        reduceMotion: true,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // The logo loader is still present, just rendered completely still.
      expect(find.byType(AymaLogoLoader), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AymaLogoLoader),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
      expect(find.text('Connecting…'), findsOneWidget);
    });

    testWidgets('live listening shows the mic and no connecting spinner', (
      tester,
    ) async {
      await pumpComposer(
        tester,
        mode: ComposerMode.listening,
        statusLabel: 'Listening…',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(find.text('Listening…'), findsOneWidget);
    });
  });

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
        expect(buffer.samples.last, inInclusiveRange(0.0, 1.3));
      }
    });

    test(
      'wiggles with more sample-to-sample direction changes than a slow, '
      'smooth drift would produce, at a sustained mid-level input',
      () {
        final buffer = AmplitudeWaveBuffer(40, random: math.Random(5));
        // Warm up past the buffer's initial fill so we're only looking at
        // steady-state behaviour.
        for (var i = 0; i < 40; i++) {
          buffer.push(0.6);
        }
        for (var i = 0; i < 40; i++) {
          buffer.push(0.6);
        }
        var directionChanges = 0;
        var lastDelta = 0.0;
        for (var i = 1; i < buffer.length; i++) {
          final delta = buffer.samples[i] - buffer.samples[i - 1];
          if (delta != 0 && lastDelta != 0 &&
              delta.sign != lastDelta.sign) {
            directionChanges++;
          }
          if (delta != 0) lastDelta = delta;
        }
        // A slow correlated random walk with no fast oscillation layered in
        // rarely reverses direction more than a handful of times across a
        // 40-sample window; the layered fast oscillation should make this a
        // genuinely busy wave instead.
        expect(directionChanges, greaterThan(10));
      },
    );
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
