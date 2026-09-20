import 'package:ayma_flutter/legal/terms_text.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flattens every RichText on screen to its plain string.
String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rt) => rt.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('renders the Terms text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: const TermsScreen(),
    ));
    await tester.pumpAndSettle();

    final text = _plain(tester);
    expect(text, contains('Ayma Terms of Service'));
    expect(text, contains('automatically analyses'));
    expect(text, contains('facial analysis and physique'));
    expect(text, contains('publicly available online'));
    expect(text, contains('cannot turn this analysis off'));
    // the stubbed sections have been filled in
    expect(text, contains('Meet in public'));
    expect(text, contains('Some AI features cost credits'));
  });

  test('kTermsText covers the disclosed points', () {
    expect(kTermsText, contains('facial analysis and physique'));
    expect(kTermsText, contains('publicly available online'));
    expect(kTermsText, contains('only about you, the account holder'));
    expect(kTermsText,
        contains('not shown in\nyour visible profile unless you ask'));
  });

  test('kTermsText has no unresolved placeholders', () {
    expect(kTermsText, isNot(contains('PLACEHOLDER')));
    expect(kTermsText, isNot(contains('[PLACEHOLDER — legal review needed]')));
  });

  test('kTermsText covers the previously stubbed sections', () {
    // Safety
    expect(kTermsText, contains('## Safety'));
    expect(kTermsText, contains('We do not verify users'));
    expect(kTermsText, contains('Emergencies are not us'));
    // Your data
    expect(kTermsText, contains('## Your data'));
    expect(kTermsText, contains('We do not sell your personal data'));
    expect(kTermsText, contains('Google Firebase'));
    expect(kTermsText, contains('LiveKit'));
    expect(kTermsText, contains('short recovery window'));
    // Payments and credits
    expect(kTermsText, contains('## Payments and credits'));
    expect(kTermsText, contains('generally non-refundable'));
    expect(kTermsText, contains('Apple App Store or Google Play'));
    // Changes to these Terms
    expect(kTermsText, contains('## Changes to these Terms'));
    expect(kTermsText, contains('that means you accept'));
    // Contact
    expect(kTermsText, contains('## Contact'));
    expect(kTermsText, contains('in-app feedback tool'));
  });

  test('kTermsText is dated today and points at the Privacy Policy', () {
    expect(kTermsText, contains('_Last updated: 2026-09-17_'));
    expect(kTermsText, contains('Privacy Policy'));
  });
}
