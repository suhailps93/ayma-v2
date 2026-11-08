import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // The stored-off regression tests seed SharedPreferences with the old
  // wing-flutter keys — the mock store keeps the seeding from hanging
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  // --- Repaint throttling (2026-09-26 perf fix: an idle orb must not
  // re-rasterise its layer on every vsync — see `_AymaOrbState._ticker`) ----

  AymaOrbPainter livePainterOf(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.descendant(
        of: find.byType(AymaOrb),
        matching: find.byType(CustomPaint),
      ))
      .map((c) => c.painter)
      .whereType<AymaOrbPainter>()
      .single;

  testWidgets('a settled idle orb is fully frozen — its clock never advances',
      (tester) async {
    await tester.pumpWidget(
      host(const AymaOrb(size: 64, state: AymaOrbState.idle)),
    );
    final t0 = livePainterOf(tester).t;
    // No matter how much time passes, an orb that mounted idle publishes
    // nothing: painted once, zero per-frame work after that.
    await tester.pump(const Duration(milliseconds: 200));
    expect(livePainterOf(tester).t, t0);
    await tester.pump(const Duration(seconds: 5));
    expect(livePainterOf(tester).t, t0);
  });

  testWidgets(
      'an idle orb DURING A LIVE CALL keeps a gentle ambient cadence — never '
      'dead-frozen (quiet moments between exchanges must not stutter)',
      (tester) async {
    await tester.pumpWidget(host(
      const AymaOrb(size: 160, state: AymaOrbState.idle, voiceLive: true),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    final t0 = livePainterOf(tester).t;
    // At the 30fps live-idle cadence, 200ms must advance the clock.
    await tester.pump(const Duration(milliseconds: 200));
    expect(livePainterOf(tester).t, greaterThan(t0));
    // ...but a single 8ms frame is withheld (60fps cadence — throttled below
    // the panel's full 120Hz rate, with margin so this isn't knife-edge).
    final t1 = livePainterOf(tester).t;
    await tester.pump(const Duration(milliseconds: 8));
    expect(livePainterOf(tester).t, t1);
  });

  testWidgets(
      'an orb returning to idle animates the transition, settles, then freezes',
      (tester) async {
    await tester.pumpWidget(
      host(const AymaOrb(size: 64, state: AymaOrbState.speaking)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(
      host(const AymaOrb(size: 64, state: AymaOrbState.idle)),
    );
    // Mid-transition (380ms curve): the clock is still being published.
    await tester.pump(const Duration(milliseconds: 100));
    final mid = livePainterOf(tester).t;
    expect(mid, greaterThan(0));
    // Let the transition finish and the settled frame publish.
    await tester.pump(const Duration(milliseconds: 400));
    final settled = livePainterOf(tester).t;
    expect(settled, greaterThanOrEqualTo(mid));
    // Frozen from here on.
    await tester.pump(const Duration(seconds: 5));
    expect(livePainterOf(tester).t, settled);
  });

  testWidgets('a speaking orb still repaints on every frame', (tester) async {
    await tester.pumpWidget(
      host(const AymaOrb(size: 160, state: AymaOrbState.speaking)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final t0 = livePainterOf(tester).t;
    await tester.pump(const Duration(milliseconds: 16));
    final t1 = livePainterOf(tester).t;
    expect(t1, greaterThan(t0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(livePainterOf(tester).t, greaterThan(t1));
  });

  testWidgets('a listening orb still repaints on every frame', (tester) async {
    await tester.pumpWidget(
      host(const AymaOrb(size: 160, state: AymaOrbState.listening)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final t0 = livePainterOf(tester).t;
    await tester.pump(const Duration(milliseconds: 16));
    expect(livePainterOf(tester).t, greaterThan(t0));
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

  // --- voiceLive silver material (founder: shiny silver while a voice call
  // is actually live, unchanged accent colour otherwise) ---------------------

  testWidgets('voiceLive renders at every state/size without throwing',
      (tester) async {
    for (final size in [18.0, 48.0, 120.0, 240.0]) {
      for (final state in AymaOrbState.values) {
        await tester.pumpWidget(host(
          AymaOrb(size: size, state: state, voiceLive: true, amplitude: 0.5),
        ));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    }
  });

  test('voiceLive:false is a no-op — identical paint to the flag not '
      'existing', () {
    final withoutFlag = painter(state: AymaOrbState.speaking, amplitude: 0.4);
    final explicitFalse = AymaOrbPainter(
      t: 0,
      fromState: AymaOrbState.speaking,
      toState: AymaOrbState.speaking,
      transitionT: 1,
      amplitude: 0.4,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      voiceLive: false,
    );
    expect(withoutFlag.shouldRepaint(explicitFalse), isFalse);
  });

  test('shouldRepaint is true when only voiceLive changes', () {
    final accentOn = painter(state: AymaOrbState.listening);
    final silverOn = AymaOrbPainter(
      t: 0,
      fromState: AymaOrbState.listening,
      toState: AymaOrbState.listening,
      transitionT: 1,
      amplitude: 0,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      voiceLive: true,
    );
    expect(accentOn.shouldRepaint(silverOn), isTrue);
  });

  testWidgets('a live call still shows visibly different talking vs '
      'listening frames in silver', (tester) async {
    // Same guard as the accent-material test above, but with the silver
    // material on — the flutter/pulse distinction must still hold once the
    // colour swap is layered on top of it.
    final speaking = AymaOrbPainter(
      t: 3.0,
      fromState: AymaOrbState.speaking,
      toState: AymaOrbState.speaking,
      transitionT: 1,
      amplitude: 0.6,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      voiceLive: true,
    );
    final listening = AymaOrbPainter(
      t: 3.0,
      fromState: AymaOrbState.listening,
      toState: AymaOrbState.listening,
      transitionT: 1,
      amplitude: 0.6,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      voiceLive: true,
    );
    expect(speaking.shouldRepaint(listening), isTrue);
  });

  // --- Wing flutter is always on (founder call, 2026-11-07) ------------
  // The Settings › Animation toggles were removed. The preferences
  // stored while they existed (`orb_wing_flutter_enabled`,
  // `orb_wing_flutter_nav_bar_enabled`) are never read anymore, so an
  // orb flutters even with both still stored off.

  testWidgets('orb flutters even with the old off preferences stored',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'orb_wing_flutter_enabled': false,
      'orb_wing_flutter_nav_bar_enabled': false,
    });
    await tester.pumpWidget(host(AymaOrb(
      size: 160,
      state: AymaOrbState.speaking,
    )));
    await tester.pump(const Duration(milliseconds: 100));
    expect(livePainterOf(tester).wingMotion, isTrue);
    final t0 = livePainterOf(tester).t;
    await tester.pump(const Duration(milliseconds: 100));
    expect(livePainterOf(tester).t, greaterThan(t0),
        reason: 'the wing clock keeps advancing — flutter is on');
  });

  testWidgets('nav-bar orb flutters too, old nav-bar off stored or not',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'orb_wing_flutter_enabled': false,
      'orb_wing_flutter_nav_bar_enabled': false,
    });
    await tester.pumpWidget(host(AymaOrb(
      size: 64,
      state: AymaOrbState.speaking,
      navBarVariant: true,
    )));
    await tester.pump(const Duration(milliseconds: 100));
    expect(livePainterOf(tester).wingMotion, isTrue);
    final t0 = livePainterOf(tester).t;
    await tester.pump(const Duration(milliseconds: 100));
    expect(livePainterOf(tester).t, greaterThan(t0),
        reason: 'the nav-bar orb flutters like every other orb');
  });

  testWidgets('state transitions still animate end to end',
      (tester) async {
    await tester.pumpWidget(host(AymaOrb(
      size: 120,
      state: AymaOrbState.idle,
    )));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(host(AymaOrb(
      size: 120,
      state: AymaOrbState.speaking,
    )));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = livePainterOf(tester);
    expect(mid.fromState, AymaOrbState.idle);
    expect(mid.toState, AymaOrbState.speaking);
    expect(mid.transitionT, lessThan(1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(livePainterOf(tester).transitionT, 1);
    expect(tester.takeException(), isNull);
  });

  test(
      'wing-motion-off rests the petals at the exact reduced-motion calm '
      'pose (pixel-identical at rest)', () async {
    Future<ui.Image> render(AymaOrbPainter p) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 160, 160),
        ui.Paint()..color = AymaColors.darkBg,
      );
      p.paint(canvas, const ui.Size(160, 160));
      final picture = recorder.endRecording();
      final image = await picture.toImage(160, 160);
      picture.dispose();
      return image;
    }

    for (final state in [AymaOrbState.listening, AymaOrbState.speaking]) {
      final flutterOff = await render(AymaOrbPainter(
        t: 0,
        fromState: state,
        toState: state,
        transitionT: 1,
        amplitude: 0,
        accent: AymaColors.accent,
        reducedMotion: false,
        showGlow: true,
        wingMotion: false,
      ));
      final reduced = await render(AymaOrbPainter(
        t: 0,
        fromState: state,
        toState: state,
        transitionT: 1,
        amplitude: 0,
        accent: AymaColors.accent,
        reducedMotion: true,
        showGlow: true,
      ));
      final a =
          (await flutterOff.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final b =
          (await reduced.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(a.buffer.asUint8List(), b.buffer.asUint8List(),
          reason: '$state resting pose must reuse the reduced-motion math');
      flutterOff.dispose();
      reduced.dispose();
    }
  });

  test('shouldRepaint is true when only wingMotion changes', () {
    final on = painter(state: AymaOrbState.speaking);
    final off = AymaOrbPainter(
      t: 0,
      fromState: AymaOrbState.speaking,
      toState: AymaOrbState.speaking,
      transitionT: 1,
      amplitude: 0,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      wingMotion: false,
    );
    expect(on.shouldRepaint(off), isTrue);
  });
}
