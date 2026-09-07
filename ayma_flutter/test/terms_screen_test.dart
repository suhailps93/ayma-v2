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
    // placeholders survive into the rendered screen
    expect(text, contains('PLACEHOLDER'));
  });

  test('kTermsText covers the disclosed points', () {
    expect(kTermsText, contains('facial analysis and physique'));
    expect(kTermsText, contains('publicly available online'));
    expect(kTermsText, contains('only about you, the account holder'));
    expect(kTermsText, contains('not shown in\nyour visible profile unless you ask'));
    expect(kTermsText, contains('[PLACEHOLDER — legal review needed]'));
  });
}
