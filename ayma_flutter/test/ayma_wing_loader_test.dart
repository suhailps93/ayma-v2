// The one shared loading indicator (founder, Nov 2026: every loading moment in
// the app shows the fluttering wing mark with a truthful status line, never a
// bare circular spinner). Confirms it renders the drawn wings tinted to the
// user's accent, drives its caption from the caller's stage, rephrases on a
// timer only when asked, and goes fully static under reduced motion.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, Color accent, {bool reduceMotion = false}) {
  final app = MaterialApp(
    theme: AymaTheme.lightWithAccent(accent),
    home: Scaffold(body: Center(child: child)),
  );
  if (!reduceMotion) return app;
  return MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: app,
  );
}

AymaWingPainter _painter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(AymaWingLoader),
      matching: find.byType(CustomPaint),
    ),
  );
  return paint.painter! as AymaWingPainter;
}

void main() {
  const accent = Color(0xFF2266CC);

  testWidgets('renders the wing mark with the default line', (tester) async {
    await tester.pumpWidget(
      _host(const AymaWingLoader(), accent),
    );
    await tester.pump();

    expect(find.byType(AymaWingLoader), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AymaWingLoader),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(find.text('Working on it…'), findsOneWidget);
  });

  testWidgets('is tinted to the user accent colour by default', (tester) async {
    await tester.pumpWidget(_host(const AymaWingLoader(), accent));
    await tester.pump();

    expect(_painter(tester).color, accent);
  });

  testWidgets('honours an explicit colour override', (tester) async {
    const override = Color(0xFF00AA00);
    await tester.pumpWidget(
      _host(const AymaWingLoader(color: override), accent),
    );
    await tester.pump();

    expect(_painter(tester).color, override);
  });

  testWidgets('flaps continuously by default', (tester) async {
    await tester.pumpWidget(_host(const AymaWingLoader(), accent));
    await tester.pump();
    final first = _painter(tester).flap;

    await tester.pump(const Duration(milliseconds: 200));
    final second = _painter(tester).flap;

    expect(first, isNot(equals(second)));
  });

  testWidgets('stage selects the line and clamps into range', (tester) async {
    const lines = ['First…', 'Second…'];
    await tester.pumpWidget(
      _host(const AymaWingLoader(lines: lines, stage: 0), accent),
    );
    await tester.pump();
    expect(find.text('First…'), findsOneWidget);

    // A stage change crossfades to the new line.
    await tester.pumpWidget(
      _host(const AymaWingLoader(lines: lines, stage: 1), accent),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Second…'), findsOneWidget);
    expect(find.text('First…'), findsNothing);

    // Out-of-range stages clamp instead of throwing.
    await tester.pumpWidget(
      _host(const AymaWingLoader(lines: lines, stage: 99), accent),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Second…'), findsOneWidget);
  });

  testWidgets('without autoRotate the line never advances on its own',
      (tester) async {
    const lines = ['First…', 'Second…'];
    await tester.pumpWidget(
      _host(const AymaWingLoader(lines: lines), accent),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));

    expect(find.text('First…'), findsOneWidget);
    expect(find.text('Second…'), findsNothing);
  });

  testWidgets('autoRotate rephrases within the operation every ~1.8s',
      (tester) async {
    const lines = ['First…', 'Second…'];
    await tester.pumpWidget(
      _host(const AymaWingLoader(lines: lines, autoRotate: true), accent),
    );
    await tester.pump();
    expect(find.text('First…'), findsOneWidget);

    // One rotation interval passes: the second rephrasing crossfades in.
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Second…'), findsOneWidget);
    expect(find.text('First…'), findsNothing);

    // …and it cycles back around.
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('First…'), findsOneWidget);
  });

  testWidgets('a stage change restarts the rotation from that step',
      (tester) async {
    const lines = ['First…', 'Second…'];
    await tester.pumpWidget(
      _host(
        const AymaWingLoader(lines: lines, autoRotate: true),
        accent,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Second…'), findsOneWidget);

    // The caller advanced the real step: the caption follows it, and the
    // rephrase cycle restarts there instead of drifting on.
    await tester.pumpWidget(
      _host(
        const AymaWingLoader(lines: lines, stage: 1, autoRotate: true),
        accent,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Second…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('First…'), findsOneWidget);
  });

  testWidgets('showLabel false renders the wings with no caption',
      (tester) async {
    await tester.pumpWidget(
      _host(const AymaWingLoader(showLabel: false), accent),
    );
    await tester.pump();

    expect(find.byType(AymaWingLoader), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AymaWingLoader),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
  });

  testWidgets('honors reduced motion: static rest pose, no flap controller',
      (tester) async {
    await tester.pumpWidget(
      _host(const AymaWingLoader(), accent, reduceMotion: true),
    );
    await tester.pump();

    // Still shows the wings…
    expect(
      find.descendant(
        of: find.byType(AymaWingLoader),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    // …but frozen at the symmetric rest pose, with nothing driving them.
    expect(_painter(tester).flap, 0.5);
    await tester.pump(const Duration(seconds: 5));
    expect(_painter(tester).flap, 0.5);
    expect(
      find.descendant(
        of: find.byType(AymaWingLoader),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
  });

  // Short viewports (300px split-screen, keyboard open, 2x text) give the
  // loader less height than wings + caption: it must degrade (shrink the
  // mark, drop the caption) instead of overflowing. Regression: the layout
  // matrix caught the first version overflowing /explore, /chat and the
  // report sheets at 300px heights.
  testWidgets('never overflows a vertically tight parent', (tester) async {
    await tester.pumpWidget(
      _host(
        const Center(
          child: SizedBox(
            height: 90,
            child: AymaWingLoader(lines: ['Finding people near you…']),
          ),
        ),
        accent,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('never overflows at 2x text scale in a short viewport',
      (tester) async {
    await tester.pumpWidget(
      _host(
        const MediaQuery(
          data: MediaQueryData(
            textScaler: TextScaler.linear(2.0),
          ),
          child: Center(
            child: SizedBox(
              height: 120,
              width: 412,
              child: AymaWingLoader(lines: ['Finding people near you…']),
            ),
          ),
        ),
        accent,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('announces a stable Loading semantics label', (tester) async {
    await tester.pumpWidget(
      _host(
        const AymaWingLoader(
          lines: ['First…', 'Second…'],
          autoRotate: true,
        ),
        accent,
      ),
    );
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(AymaWingLoader)).label,
      'Loading',
    );
  });
}
