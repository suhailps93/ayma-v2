// The branded animated-logo loader (founder: "the Ayma logo should have a
// loading animation"). It is now reserved for the VOICE wake/connect state only
// (the chat composer's connecting slot) — page/report loads use the standard
// `AppLoadingIndicator` (see `app_loading_indicator_test.dart`). Confirms it
// renders the logo, animates by default, and goes completely still under
// reduced motion — the latter matters because the voice-connect state must not
// keep ticking when the user has asked the OS to reduce motion.
import 'package:ayma_flutter/widgets/ayma_logo_loader.dart';
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
  testWidgets('renders the Ayma logo image', (tester) async {
    await tester.pumpWidget(_host(const AymaLogoLoader(size: 64)));
    await tester.pump();

    expect(find.byType(AymaLogoLoader), findsOneWidget);
    // The orb mark itself is drawn as an Image inside the loader.
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  testWidgets('animates (pulses) by default', (tester) async {
    await tester.pumpWidget(_host(const AymaLogoLoader(size: 64)));
    await tester.pump();

    // The breathing pulse / halo is driven by an AnimatedBuilder on a repeating
    // controller — present only when motion is allowed.
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(AnimatedBuilder),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('honors reduced motion: static, no pulse controller',
      (tester) async {
    await tester.pumpWidget(
      _host(const AymaLogoLoader(size: 64), reduceMotion: true),
    );
    await tester.pump();

    // Still shows the logo…
    expect(
      find.descendant(
        of: find.byType(AymaLogoLoader),
        matching: find.byType(Image),
      ),
      findsOneWidget,
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
