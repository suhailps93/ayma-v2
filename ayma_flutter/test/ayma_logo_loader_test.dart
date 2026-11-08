// The branded animated-logo loader (founder: "the Ayma logo should have a
// loading animation"). It is now reserved for the VOICE wake/connect state only
// (the chat composer's connecting slot) — page/report loads use the shared
// `AymaWingLoader` (see `ayma_wing_loader_test.dart`). Confirms it
// renders the logo, animates by default, and goes completely still under
// reduced motion — the latter matters because the voice-connect state must not
// keep ticking when the user has asked the OS to reduce motion.
import 'package:ayma_flutter/widgets/ayma_logo_loader.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

void main() {
  testWidgets('renders the canonical Ayma orb, not a picture file',
      (tester) async {
    await tester.pumpWidget(_host(const AymaLogoLoader(size: 64)));
    await tester.pump();

    expect(find.byType(AymaLogoLoader), findsOneWidget);
    // The mark is the live AymaOrb widget (the single logo source) — a
    // bundled PNG here would freeze the loader at the default accent.
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(AymaOrb),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(Image),
      ),
      findsNothing,
    );
  });

  testWidgets('animates (pulses) by default', (tester) async {
    await tester.pumpWidget(_host(const AymaLogoLoader(size: 64)));
    await tester.pump();

    // The breathing pulse / halo is driven by an AnimatedBuilder on a repeating
    // controller — present only when motion is allowed (the orb's own internal
    // AnimatedBuilder rides along, so this is at-least-one, not exactly one).
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(AnimatedBuilder),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('honors reduced motion: static, no pulse controller',
      (tester) async {
    await tester.pumpWidget(
      _host(const AymaLogoLoader(size: 64), reduceMotion: true),
    );
    await tester.pump();

    // Still shows the logo — as the static canonical mark…
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(AymaOrbMark),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(Image),
      ),
      findsNothing,
    );
    // …but with no animated pulse wrapper at all.
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
  });

  testWidgets('shows the optional label', (tester) async {
    await tester.pumpWidget(
      _host(const AymaLogoLoader(size: 64, label: 'Loading your report…')),
    );
    await tester.pump();

    expect(find.text('Loading your report…'), findsOneWidget);
  });
}
