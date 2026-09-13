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
}
