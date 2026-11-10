import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/phone_number_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cluster-12 jobs pass, defect 17 (V9): the country-picker button inside the
/// phone field was rendering ~20 tall (shrink-wrapped `Size.zero`), far below
/// the 44 absolute-minimum tap floor. The fix sets `minimumSize: Size(0, 44)`
/// while keeping `shrinkWrap` + the horizontal-8 padding, so the button grows
/// to 44 WITHOUT growing the field itself.
Widget _host(TextEditingController ctrl) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: PhoneNumberField(controller: ctrl),
        ),
      ),
    );

void main() {
  testWidgets('the country-picker button renders at least 44 tall',
      (tester) async {
    await tester.pumpWidget(_host(TextEditingController()));
    await tester.pumpAndSettle();

    final btn = find.byType(TextButton);
    expect(btn, findsOneWidget);
    // shrinkWrap tap target => the button renders its exact minimumSize of 44
    // (content ~19.5 < 44), clearing the 44 floor with no padded 48 bump.
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(44.0));
  });

  testWidgets('the field height is unchanged by the button fix (~45, not grown)',
      (tester) async {
    await tester.pumpWidget(_host(TextEditingController()));
    await tester.pumpAndSettle();

    // The 44-tall button fits inside the framework field box (16pt titleMedium
    // line + the outline 12/20/12/12 content padding ~= 45), so the field never
    // grows past the normal single-line field height.
    final h = tester.getSize(find.byType(TextField)).height;
    expect(h, greaterThanOrEqualTo(44.0));
    expect(h, lessThanOrEqualTo(64.0));
  });

  testWidgets('tapping the country button still opens the picker',
      (tester) async {
    await tester.pumpWidget(_host(TextEditingController()));
    await tester.pumpAndSettle();

    // Before: just the phone field itself.
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The country picker pushes a modal with its own search field, so a second
    // TextField now exists — the picker opened (behavior unchanged).
    expect(find.byType(TextField), findsWidgets);
    expect(tester.widgetList(find.byType(TextField)).length,
        greaterThan(1));
  });
}
