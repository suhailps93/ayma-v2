// P1 regression (Scout, build 2243+): at `adb shell wm size 720x1280` the
// bottom tab bar reported "RIGHT OVERFLOWED BY 5.7 PIXELS" over the You tab
// while every content layout adapted fine. `wm size` sets physical pixels;
// the bench emulator's 420dpi density (device pixel ratio 2.625) makes that
// ~274x488 logical — narrower than the bar's old fixed 280px-wide row
// (4 x 48px tabs + the 88px orb tab), hence exactly 280 - 274.3 = 5.7px of
// overflow. The layout matrix never caught it because its narrowest width is
// 320 logical.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host() => MaterialApp(
    theme: AymaTheme.light,
    home: Scaffold(
      bottomNavigationBar: AymaTabBar(
        index: -1,
        voice: null,
        onSelected: (_) {},
      ),
    ),
  );

  testWidgets('tab bar fits the Scout P1 window: 720x1280 @ 420dpi', (
    tester,
  ) async {
    // Faithful bench condition: physical size plus the emulator density, so
    // the logical window is ~274x488 — the size that overflowed.
    tester.view.devicePixelRatio = 420 / 160;
    tester.view.physicalSize = const Size(720, 1280);
    addTearDown(tester.view.reset);

    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString().split('\n').first);
    };
    try {
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 400));

      // Guard the test's own premise: this window must actually be narrower
      // than the bar's old fixed 280px row, or a pass would be vacuous.
      final size = tester.getSize(find.byType(Scaffold));
      expect(size.width, lessThan(280));

      // Unmount inside the guarded window so dispose-time errors count too.
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      FlutterError.onError = previous;
    }
    expect(
      errors,
      isEmpty,
      reason: 'Layout errors (${errors.length}):\n${errors.join('\n')}',
    );
  });

  testWidgets('tab bar geometry is unchanged at a normal phone width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();

    // The old fixed geometry: 280px of tabs in a 390px row with spaceAround
    // (11px end gaps), so Explore (48px) centers at 35 and Profile at 355.
    // The narrow-window fix must not move a pixel here.
    double dxOf(String label) => tester.getCenter(find.byTooltip(label)).dx;
    expect(dxOf('Explore'), moreOrLessEquals(35));
    expect(dxOf('Profile'), moreOrLessEquals(355));
  });
}
