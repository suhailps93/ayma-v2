import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/completeness_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Jobs token follow-up — widget-level verification at the changed call sites.
///
/// V1 (track distinct), V2 (button minimums render 48 after the local-override
/// removal), V3 (field errorStyle routes through the card-safe token), and V5
/// (card/field boundaries use the boundary token) — pumped under both themes.
///
/// The theme is built lazily INSIDE each test body (never at collection time),
/// so the google_fonts asset load happens under the test binding — the same
/// pattern the passing screen tests use.
void main() {
  Widget host(ThemeData theme, Widget child) => MaterialApp(
        theme: theme,
        home: Scaffold(body: Center(child: child)),
      );

  final themes = <(String, ThemeData Function())>[
    ('light', () => AymaTheme.light),
    ('dark', () => AymaTheme.dark),
  ];

  for (final (name, make) in themes) {
    // --- V2: button minimums render 48 (not 40, not 44) after the theme-level
    // minimums replace the 11 local overrides. All removed controls were plain
    // TextButtons / SegmentedButtons; the one kept-local control is a
    // FilledButton with a local Size(0, 44) (load-bearing, see
    // profile_proposals_screen). Each renders 48 via the padded tap target.
    testWidgets('V2: TextButton renders 48 tall via theme minimum ($name)',
        (tester) async {
      await tester.pumpWidget(
          host(make(), TextButton(onPressed: () {}, child: const Text('OK'))));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(TextButton)).height, 48.0);
    });

    testWidgets('V2: SegmentedButton renders 48 tall via theme minimum ($name)',
        (tester) async {
      await tester.pumpWidget(host(
        make(),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('A')),
            ButtonSegment(value: 1, label: Text('B')),
          ],
          selected: const {0},
          onSelectionChanged: (_) {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SegmentedButton<int>)).height, 48.0);
    });

    testWidgets('V2: kept-local FilledButton (Size(0,44)) renders 48 ($name)',
        (tester) async {
      await tester.pumpWidget(host(
        make(),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () {},
          child: const Text('Apply'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(FilledButton)).height, 48.0);
    });

    testWidgets(
        'V2: theme TextButton + SegmentedButton minimums are Size(0,44) '
        '($name)', (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final t = Theme.of(tester.element(find.byType(SizedBox)));
      expect(t.textButtonTheme.style!.minimumSize?.resolve({}),
          const Size(0, 44));
      expect(t.segmentedButtonTheme.style!.minimumSize?.resolve({}),
          const Size(0, 44));
    });

    // --- V1: completeness ring track uses ac.track (distinct from bg and
    // fill), at both ring sizes.
    for (final size in <double>[56, 72]) {
      testWidgets('V1: CompletenessRing size $size paints ac.track ($name)',
          (tester) async {
        await tester.pumpWidget(host(make(), CompletenessRing(score: 42, size: size)));
        await tester.pumpAndSettle();
        final ac = tester.element(find.byType(CompletenessRing)).ac;
        expect(AymaColors.contrastRatio(ac.track, ac.bg),
            greaterThanOrEqualTo(3.0),
            reason: 'track distinct from bg');
        expect(AymaColors.contrastRatio(ac.track, ac.accent),
            greaterThanOrEqualTo(2.9),
            reason: 'track distinct from fill');
        expect(find.byType(CompletenessRing), findsOneWidget);
      });
    }

    // --- V1: slider inactive track routes through the track token (theme).
    testWidgets('V1: sliderTheme.inactiveTrackColor == track ($name)',
        (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      expect(Theme.of(ctx).sliderTheme.inactiveTrackColor, ctx.ac.track);
    });

    // --- V3: field errorStyle routes through the card-safe error token (the
    // helper renders on the containing surface, bgCard inside dialogs).
    testWidgets('V3: inputDecorationTheme.errorStyle == errorTextCard ($name)',
        (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      expect(Theme.of(ctx).inputDecorationTheme.errorStyle!.color,
          ctx.ac.errorTextCard);
    });

    // --- V5: cardTheme + TextField borders route through the boundary token.
    testWidgets('V5: cardTheme and TextField borders use boundary ($name)',
        (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      final t = Theme.of(ctx);
      final cardShape = t.cardTheme.shape! as RoundedRectangleBorder;
      expect(cardShape.side.color, ctx.ac.boundary);
      final enabled =
          t.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderSide.color, ctx.ac.boundary);
    });

    // --- R8: outlinedButtonTheme side routes through boundary and the live
    // side colour clears 3:1 on bg, bgElev and bgCard (the family default for
    // all nine OutlinedButtons; none carries a per-button side override).
    testWidgets(
        'R8: outlinedButtonTheme side == boundary, >=3:1 on bg/bgElev/bgCard '
        '($name)', (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      final t = Theme.of(ctx);
      final side = t.outlinedButtonTheme.style!.side!.resolve({})!;
      expect(side.color, ctx.ac.boundary, reason: 'side routes through boundary');
      for (final (label, surface) in [
        ('bg', ctx.ac.bg),
        ('bgElev', ctx.ac.bgElev),
        ('bgCard', ctx.ac.bgCard),
      ]) {
        final ratio = AymaColors.contrastRatio(side.color, surface);
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: 'OutlinedButton side vs $label = $ratio');
      }
    });

    // --- R9: chipTheme side routes through boundary and clears 3:1 on
    // bg/bgElev/bgCard (the chip family default; no per-chip override).
    testWidgets(
        'R9: chipTheme side == boundary, >=3:1 on bg/bgElev/bgCard ($name)',
        (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      final side = Theme.of(ctx).chipTheme.side!;
      expect(side.color, ctx.ac.boundary, reason: 'side routes through boundary');
      for (final (label, surface) in [
        ('bg', ctx.ac.bg),
        ('bgElev', ctx.ac.bgElev),
        ('bgCard', ctx.ac.bgCard),
      ]) {
        final ratio = AymaColors.contrastRatio(side.color, surface);
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: 'Chip side vs $label = $ratio');
      }
    });

    // --- R9: with the theme applied (standard density, no per-chip override),
    // the chip family tap target clears the 44 floor (48 target via the padded
    // tap target). The per-widget plan ChoiceChip density fix is separate.
    testWidgets('R9: chip family tap target >=44 with the theme ($name)',
        (tester) async {
      await tester.pumpWidget(
          host(make(), ActionChip(label: const Text('X'), onPressed: () {})));
      await tester.pumpAndSettle();
      final h = tester.getSize(find.byType(ActionChip)).height;
      expect(h, greaterThanOrEqualTo(44.0),
          reason: 'chip tap target height = $h');
    });

    // --- R12: switchTheme routes the INACTIVE track outline through boundary so
    // the OFF state clears 3:1 on bg. The ACTIVE (selected) state is untouched:
    // its outline stays transparent (M3 default), track keeps the accent fill.
    testWidgets(
        'R12: switch inactive track outline == boundary, >=3:1 on bg; selected '
        'untouched ($name)', (tester) async {
      await tester.pumpWidget(host(make(), const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      final outlineProp = Theme.of(ctx).switchTheme.trackOutlineColor!;
      final inactive = outlineProp.resolve(<WidgetState>{})!;
      expect(inactive, ctx.ac.boundary, reason: 'inactive outline == boundary');
      final ratio = AymaColors.contrastRatio(inactive, ctx.ac.bg);
      expect(ratio, greaterThanOrEqualTo(3.0),
          reason: 'inactive track outline vs bg = $ratio');
      final selected = outlineProp.resolve(<WidgetState>{WidgetState.selected});
      expect(selected, Colors.transparent,
          reason: 'active state outline untouched (transparent)');
    });
  }
}
