import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host() =>
      MaterialApp(theme: AymaTheme.light, home: const MainShellScreen());

  testWidgets(
    'renders the 4-tab bottom nav (icon-only, no text labels) with the '
    'orb on the Ayma tab',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await tester.pump();

      // No painted text labels any more — each tab keeps its name only as an
      // accessible Tooltip.
      for (final label in ['AYMA', 'EXPLORE', 'MESSAGES', 'PROFILE']) {
        expect(find.text(label), findsNothing);
      }
      for (final label in ['Ayma', 'Explore', 'Messages', 'Profile']) {
        expect(find.byTooltip(label), findsOneWidget);
      }
      // The Ayma destination uses the brand orb, not an Icon.
      expect(find.byType(AymaOrb), findsWidgets);
    },
  );

  testWidgets('tapping Explore builds and shows the Explore tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byType(ExploreScreen), findsNothing);

    await tester.tap(find.byTooltip('Explore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ExploreScreen), findsOneWidget);
  });

  testWidgets('back walks tab history instead of leaving the app', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();

    // Ayma -> Explore -> Ayma -> Explore. (Stick to these two tabs — the others
    // need Firebase, which isn't initialised in a widget test.)
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Ayma'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));

    // Android back presses walk that history back one step at a time, then the
    // shell stops handling the press so the app can close.
    final dynamic shell = tester.state<State>(find.byType(MainShellScreen));
    expect(shell.popTabForTest(), isTrue);
    expect(shell.popTabForTest(), isTrue);
    expect(shell.popTabForTest(), isTrue);
    expect(shell.popTabForTest(), isFalse); // back at the root entry
  });
}
