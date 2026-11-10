// Jobs pass (Wave 1, cluster 13 — fleet/jobs-shell-nav). Covers the three
// ayma_primitives defects this pass fixed:
//   - defect 2: AymaScreenHeader default right padding 12 -> 20, so the
//     trailing action sits at the 20 edge, matching the title's 20 left edge.
//   - defect 3: the eyebrow -> title gap is on the 8pt grid (10 -> 8).
//   - defect 4: CreditPill's default non-dim colour is the text-safe
//     `accentText` (4.5:1 in both themes), not raw accent (3.83 light); the
//     zero-balance dim path still renders `fgMute`.
// There was no ayma_primitives test before this pass.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(ThemeData theme, Widget child) => MaterialApp(
        theme: theme,
        home: Scaffold(body: child),
      );

  group('AymaScreenHeader — defect 2: 20/20 content edges', () {
    // A header with no back button: the title's left edge and the trailing
    // action's right edge must both sit at the 20 screen edge. Checked in both
    // themes at 2.0x text scale (horizontal insets are fixed, so text scale
    // must not shift either edge). Themes are built inside each test (they load
    // fonts via google_fonts, which needs the test binding/zone).
    for (final (name, buildTheme, ac) in <(String, ThemeData Function(), AymaTokens)>[
      ('light', () => AymaTheme.light, AymaTokens.light),
      ('dark', () => AymaTheme.dark, AymaTokens.dark),
    ]) {
      testWidgets('$name @2.0x: title at 20 left, action at 20 right',
          (tester) async {
        await tester.pumpWidget(
          host(
            buildTheme(),
            const MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: AymaScreenHeader(
                title: 'Explore',
                action: SizedBox(
                  key: Key('headerAction'),
                  width: 24,
                  height: 24,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final screenWidth = tester.getSize(find.byType(Scaffold)).width;
        final titleLeft = tester.getRect(find.text('Explore')).left;
        final actionRight =
            tester.getRect(find.byKey(const Key('headerAction'))).right;

        expect(titleLeft, moreOrLessEquals(20, epsilon: 0.01),
            reason: 'title should sit at the 20 left edge');
        expect(actionRight, moreOrLessEquals(screenWidth - 20, epsilon: 0.01),
            reason: 'trailing action should sit at the 20 right edge');
        // Sanity: the ac is wired (not an unused binding).
        expect(ac.fg, isNotNull);
      });
    }
  });

  testWidgets('AymaScreenHeader — defect 3: eyebrow -> title gap is 8pt',
      (tester) async {
    await tester.pumpWidget(
      host(
        AymaTheme.light,
        const AymaScreenHeader(eyebrow: 'SECTION', title: 'Explore'),
      ),
    );
    await tester.pump();

    final eyebrowBottom = tester.getRect(find.text('SECTION')).bottom;
    final titleTop = tester.getRect(find.text('Explore')).top;
    expect(titleTop - eyebrowBottom, moreOrLessEquals(8, epsilon: 0.01),
        reason: 'the eyebrow -> title gap must be on the 8pt grid');
  });

  group('CreditPill — defect 4: default colour is text-safe accentText', () {
    for (final (name, buildTheme, ac) in <(String, ThemeData Function(), AymaTokens)>[
      ('light', () => AymaTheme.light, AymaTokens.light),
      ('dark', () => AymaTheme.dark, AymaTokens.dark),
    ]) {
      testWidgets('$name: non-dim pill paints coin + number in accentText',
          (tester) async {
        await tester.pumpWidget(host(buildTheme(), const CreditPill(amount: 12)));
        await tester.pump();

        final icon = tester.widget<Icon>(find.byIcon(Icons.toll_rounded));
        final text = tester.widget<Text>(find.text('12'));
        expect(icon.color, ac.accentText,
            reason: 'coin glyph uses the text-safe accent');
        expect(text.style?.color, ac.accentText,
            reason: 'number uses the text-safe accent (was raw accent, '
                '3.83:1 light)');
        // One accent, one job: it is the derived text-safe accent, never the
        // raw accent that fails the light bg text floor.
        expect(text.style?.color, isNot(ac.accent));
      });

      testWidgets('$name: zero-balance dim pill keeps fgMute', (tester) async {
        await tester.pumpWidget(
          host(buildTheme(), const CreditPill(amount: 0, dim: true)),
        );
        await tester.pump();

        final icon = tester.widget<Icon>(find.byIcon(Icons.toll_rounded));
        final text = tester.widget<Text>(find.text('0'));
        expect(icon.color, ac.fgMute);
        expect(text.style?.color, ac.fgMute);
      });
    }
  });
}
