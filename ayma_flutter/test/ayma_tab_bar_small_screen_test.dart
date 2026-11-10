// P1 regression (Scout, build 2243+): at `adb shell wm size 720x1280` the
// bottom tab bar reported "RIGHT OVERFLOWED BY 5.7 PIXELS" over the You tab
// while every content layout adapted fine. `wm size` sets physical pixels;
// the bench emulator's 420dpi density (device pixel ratio 2.625) makes that
// ~274x488 logical — narrower than the bar's old fixed 280px-wide row
// (4 x 48px tabs + the 88px orb tab), hence exactly 280 - 274.3 = 5.7px of
// overflow. The layout matrix never caught it because its narrowest width is
// 320 logical.
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A minimal live-and-quiet voice session, so the orb-centering checks can run
// "with the quiet badge showing" (V1) — the badge sits inside the orb tab's
// own padding, so it must not shift the orb's center off bar width/2.
class _QuietVoice extends VoiceSessionController {
  _QuietVoice() : super(transcriptStore: TranscriptStore());

  @override
  VoiceSessionPhase get phase => VoiceSessionPhase.live;

  @override
  bool get isActive => true;

  @override
  bool get isListening => true;

  @override
  bool get aymaQuiet => true;
}

void main() {
  Widget host({bool quiet = false}) => MaterialApp(
    theme: AymaTheme.light,
    home: Scaffold(
      bottomNavigationBar: AymaTabBar(
        index: -1,
        voice: quiet ? _QuietVoice() : null,
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

  // V1 (brief): the center orb's center x equals the bar width / 2 for ANY
  // width and mode — the width algebra (spaceAround, five children, the orb's
  // own width cancelling) proves it; assert it, do not "fix" alignment. Both
  // non-compact and compact, at 390 and 274 logical widths, with the quiet
  // badge showing.
  for (final compact in [false, true]) {
    // height >= 480 -> normal; < 480 -> compact.
    final height = compact ? 400.0 : 844.0;
    for (final width in [390.0, 274.0]) {
      testWidgets(
        'orb center sits at bar width/2 — ${width.toInt()}px, '
        '${compact ? "compact" : "normal"} mode (quiet badge showing)',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = Size(width, height);
          addTearDown(tester.view.reset);

          await tester.pumpWidget(host(quiet: true));
          await tester.pump();

          final barWidth = tester.getSize(find.byType(Scaffold)).width;
          final orbCenter = tester.getCenter(find.byTooltip('Ayma')).dx;
          expect(orbCenter, moreOrLessEquals(barWidth / 2, epsilon: 0.5),
              reason: 'orb must be centered on the bar');
        },
      );
    }
  }

  // V2 (brief): after defect 1 (compact vertical padding 8 -> 10), the compact
  // non-orb tabs clear the 44 absolute-minimum touch floor (24 content + 2x10
  // = 44), and the compact bar height constant is unchanged (the orb child,
  // 40 + 2x4 = 48, is still the tallest, so compactContentHeight stays 56).
  testWidgets('compact non-orb tabs render 44 tall and clear the floor', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 400); // height < 480 -> compact
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();

    for (final label in ['Explore', 'Messages', 'Profile', 'Notifications']) {
      expect(tester.getSize(find.byTooltip(label)).height,
          moreOrLessEquals(44, epsilon: 0.01),
          reason: '$label tab must be 44 tall in compact mode');
    }
  });

  test('compactContentHeight is unchanged (orb child still tallest at 48)', () {
    expect(AymaTabBar.compactContentHeight, 56.0);
  });
}
