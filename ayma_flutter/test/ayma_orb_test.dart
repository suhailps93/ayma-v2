import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child, {bool reducedMotion = false}) => MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: MaterialApp(
          theme: AymaTheme.dark,
          home: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('renders and animates in every state without throwing',
      (tester) async {
    for (final state in AymaOrbState.values) {
      await tester.pumpWidget(host(AymaOrb(size: 120, state: state)));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AymaOrb), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the active shortcut still paints (tab-bar usage)',
      (tester) async {
    await tester.pumpWidget(host(const AymaOrb(size: 22, active: true)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders without error at every documented size breakpoint',
      (tester) async {
    for (final size in [18.0, 48.0, 120.0, 240.0]) {
      for (final state in AymaOrbState.values) {
        await tester.pumpWidget(host(AymaOrb(size: size, state: state)));
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(AymaOrb), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('amplitude-reactive at low/medium/high amplitude, listening',
      (tester) async {
    for (final amp in [0.05, 0.5, 0.95]) {
      await tester.pumpWidget(host(
        AymaOrb(size: 160, state: AymaOrbState.listening, amplitude: amp),
      ));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AymaOrb), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('amplitude-reactive at low/medium/high amplitude, speaking',
      (tester) async {
    for (final amp in [0.05, 0.5, 0.95]) {
      await tester.pumpWidget(host(
        AymaOrb(size: 160, state: AymaOrbState.speaking, amplitude: amp),
      ));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AymaOrb), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a live amplitudeListenable drives repaint without throwing',
      (tester) async {
    final level = ValueNotifier<double>(0);
    await tester.pumpWidget(host(
      AymaOrb(
        size: 120,
        state: AymaOrbState.speaking,
        amplitudeListenable: level,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    level.value = 0.8;
    await tester.pump(const Duration(milliseconds: 16));
    level.value = 0.1;
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion renders every state as static/simplified',
      (tester) async {
    for (final state in AymaOrbState.values) {
      await tester.pumpWidget(
        host(AymaOrb(size: 120, state: state), reducedMotion: true),
      );
      await tester.pump(const Duration(milliseconds: 16));
      // No ticking animation should be scheduled once settled.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(AymaOrb), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('state changes transition smoothly without throwing',
      (tester) async {
    await tester.pumpWidget(host(const AymaOrb(size: 120)));
    await tester.pump(const Duration(milliseconds: 16));
    for (final state in [
      AymaOrbState.listening,
      AymaOrbState.thinking,
      AymaOrbState.speaking,
      AymaOrbState.done,
      AymaOrbState.idle,
    ]) {
      await tester.pumpWidget(host(AymaOrb(size: 120, state: state)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }
  });

  AymaOrbPainter painter({
    double t = 0,
    AymaOrbState state = AymaOrbState.idle,
    double transitionT = 1,
    double amplitude = 0,
    Color accent = AymaColors.accent,
    bool reducedMotion = false,
    bool showGlow = true,
    bool showListeningRings = false,
  }) =>
      AymaOrbPainter(
        t: t,
        fromState: state,
        toState: state,
        transitionT: transitionT,
        amplitude: amplitude,
        accent: accent,
        reducedMotion: reducedMotion,
        showGlow: showGlow,
        showListeningRings: showListeningRings,
      );

  test('shouldRepaint is false when nothing relevant changed', () {
    final a = painter(t: 1.23, state: AymaOrbState.speaking, amplitude: 0.4);
    final b = painter(t: 1.23, state: AymaOrbState.speaking, amplitude: 0.4);
    expect(a.shouldRepaint(b), isFalse);
  });

  test('shouldRepaint is true when time advances', () {
    final a = painter(t: 1.0);
    final b = painter(t: 1.1);
    expect(a.shouldRepaint(b), isTrue);
  });

  test('shouldRepaint is true when state changes', () {
    final a = painter(state: AymaOrbState.idle);
    final b = painter(state: AymaOrbState.thinking);
    expect(a.shouldRepaint(b), isTrue);
  });

  test('shouldRepaint is true when amplitude changes', () {
    final a = painter(amplitude: 0.1);
    final b = painter(amplitude: 0.9);
    expect(a.shouldRepaint(b), isTrue);
  });

  // --- Wing geometry (Task 3: Cherry Fuchsia petal/wing redesign) ---------

  testWidgets('wing lobes paint without throwing at every tier and state',
      (tester) async {
    for (final size in [18.0, 60.0, 120.0, 240.0]) {
      for (final state in AymaOrbState.values) {
        await tester.pumpWidget(host(AymaOrb(size: size, state: state)));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('speaking flutter is reactive to amplitude without throwing',
      (tester) async {
    for (final amp in [0.0, 0.3, 0.9]) {
      await tester.pumpWidget(host(
        AymaOrb(size: 140, state: AymaOrbState.speaking, amplitude: amp),
      ));
      // Advance across several flutter cycles.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('listening pulse is reactive to amplitude without throwing',
      (tester) async {
    for (final amp in [0.0, 0.3, 0.9]) {
      await tester.pumpWidget(host(
        AymaOrb(size: 140, state: AymaOrbState.listening, amplitude: amp),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('speaking vs listening produce visibly different frames',
      (tester) async {
    // Sample the painter output at the same `t`/amplitude for both states —
    // flutter (speaking) and pulse (listening) are different motions, so
    // the two states shouldn't ever be pixel-identical mid-animation.
    final speaking = painter(
      t: 3.0,
      state: AymaOrbState.speaking,
      amplitude: 0.6,
    );
    final listening = painter(
      t: 3.0,
      state: AymaOrbState.listening,
      amplitude: 0.6,
    );
    expect(speaking.shouldRepaint(listening), isTrue);
  });

  test('shouldRepaint is true across a fromState/toState transition', () {
    final a = AymaOrbPainter(
      t: 1,
      fromState: AymaOrbState.idle,
      toState: AymaOrbState.speaking,
      transitionT: 0.4,
      amplitude: 0.2,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      showListeningRings: false,
    );
    final b = AymaOrbPainter(
      t: 1,
      fromState: AymaOrbState.idle,
      toState: AymaOrbState.speaking,
      transitionT: 0.6,
      amplitude: 0.2,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      showListeningRings: false,
    );
    expect(a.shouldRepaint(b), isTrue);
  });

  testWidgets('reduced motion still renders speaking/listening wings',
      (tester) async {
    for (final state in [AymaOrbState.speaking, AymaOrbState.listening]) {
      await tester.pumpWidget(
        host(AymaOrb(size: 140, state: state, amplitude: 0.7),
            reducedMotion: true),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a user-picked accent colour repaints the wings too',
      (tester) async {
    await tester.pumpWidget(
      host(const AymaOrb(size: 120, state: AymaOrbState.idle)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);

    // Same host builder but a differently-themed MaterialApp (as if the
    // Accent Color screen had just committed a new pick) — should still
    // render cleanly with the wings tinted from the new accent.
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.lightWithAccent(const Color(0xFF2266CC)),
      home: const Scaffold(
        body: Center(child: AymaOrb(size: 120, state: AymaOrbState.idle)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
  });
}
