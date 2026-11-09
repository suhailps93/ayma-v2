import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/partner_preferences_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 25);

  Widget host({double width = 360}) => MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: PartnerPreferencesFields(
                ages: const RangeValues(25, 38),
                distance: '50',
                onAgesChanged: (_) {},
                onDistanceChanged: (_) {},
              ),
            ),
          ),
        ),
      );

  // V1 — the age RangeSlider renders 48 tall (M3 overlay 2x24), clearing the
  // 44 touch floor.
  testWidgets('age RangeSlider renders 48 tall', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(RangeSlider)).height, 48);
  });

  // V2 / defect 7 — the distance chips Wrap carries runSpacing 8 (keeping
  // spacing 8), and at 360pt the five chips wrap onto two rows so the gap is
  // visible, not touching.
  testWidgets('distance chips wrap to two rows with 8 runSpacing at 360pt',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final wrap = tester.widget<Wrap>(
        find.ancestor(of: find.text('Anywhere is fine'), matching: find.byType(Wrap)));
    expect(wrap.spacing, 8);
    expect(wrap.runSpacing, 8);

    expect(find.byType(ChoiceChip), findsNWidgets(5));
    // Distinct top offsets among the chips => they wrapped onto >1 row, so the
    // 8 runSpacing is a visible gap, not a no-op.
    final ys = find.byType(ChoiceChip).evaluate().map((e) {
      final box = e.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero).dy;
    }).toSet();
    expect(ys.length, greaterThanOrEqualTo(2),
        reason: 'chips should occupy at least two rows at 360pt');
  });

  test('default age range is the user age -5 to +8', () {
    final r = defaultPartnerAgeRange(DateTime(1996, 5, 4), now: now); // 30
    expect(r.start, 25);
    expect(r.end, 38);
  });

  test('default age range never goes below the 18 floor', () {
    final r = defaultPartnerAgeRange(DateTime(2007, 1, 1), now: now); // 19
    expect(r.start, 18);
    expect(r.end, 27);
  });

  test('a birthday later this year does not count yet; no birthdate -> full',
      () {
    expect(defaultPartnerAgeRange(DateTime(1996, 12, 1), now: now).start, 24);
    final full = defaultPartnerAgeRange(null, now: now);
    expect(full.start, 18);
    expect(full.end, 99);
  });
}
