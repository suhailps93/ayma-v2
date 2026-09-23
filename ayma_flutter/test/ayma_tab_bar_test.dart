// The shared bottom nav bar (§ persistent nav bar, every screen, no
// exceptions): both MainShellScreen and every NavBarShell-wrapped screen
// render this same widget. Covers the two things this task's redesign
// changed: the Ayma orb reading noticeably bigger than the other three icons,
// and `index: -1` (a screen outside the shell) leaving nothing highlighted.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({required int index, ValueChanged<int>? onSelected}) =>
      MaterialApp(
        theme: AymaTheme.light,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: index,
            voiceActive: false,
            onSelected: onSelected ?? (_) {},
          ),
        ),
      );

  testWidgets('the Ayma orb renders noticeably larger than the other icons', (
    tester,
  ) async {
    await tester.pumpWidget(host(index: 0));
    await tester.pump();

    final orb = tester.widget<AymaOrb>(find.byType(AymaOrb));
    // Was 22 before this task's redesign; must read as clearly bigger, but
    // still restrained (nowhere near a "large" breakpoint orb) so it doesn't
    // dominate the bar.
    expect(orb.size, greaterThanOrEqualTo(28));
    expect(orb.size, lessThanOrEqualTo(40));

    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    expect(icons, isNotEmpty);
    for (final icon in icons) {
      expect(icon.size, lessThan(orb.size));
    }
  });

  testWidgets('index -1 highlights none of the three plain icons', (
    tester,
  ) async {
    await tester.pumpWidget(host(index: -1));
    await tester.pump();

    final ac = AymaTokens.light;
    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    expect(icons, hasLength(3)); // Explore / Messages / Profile
    for (final icon in icons) {
      expect(icon.color, ac.fgMute);
    }
  });

  testWidgets('a selected index highlights only that plain icon', (
    tester,
  ) async {
    await tester.pumpWidget(host(index: 1)); // Explore
    await tester.pump();

    final ac = AymaTokens.light;
    // Explore is first of the three plain-icon tabs.
    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    expect(icons.first.color, ac.fg);
    expect(icons[1].color, ac.fgMute);
    expect(icons[2].color, ac.fgMute);
  });

  testWidgets('tapping each tab reports its own index', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(host(index: -1, onSelected: taps.add));
    await tester.pump();

    for (final label in ['Ayma', 'Explore', 'Messages', 'Profile']) {
      await tester.tap(find.byTooltip(label));
    }
    await tester.pump();

    expect(taps, [0, 1, 2, 3]);
  });
}
