import 'package:ayma_flutter/legal/privacy_text.dart';
import 'package:ayma_flutter/screens/privacy_screen.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flattens every RichText on screen to its plain string.
String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rt) => rt.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('renders the Privacy Policy text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();

    final text = _plain(tester);
    expect(text, contains('Ayma Privacy Policy'));
    expect(text, contains('Data we collect'));
    expect(text, contains('automatically analyses your own photos'));
    expect(text, isNot(contains('**')));
  });

  test('kPrivacyText covers the disclosed points', () {
    // subprocessors
    expect(kPrivacyText, contains('Google Firebase'));
    expect(kPrivacyText, contains('Google Gemini / Vertex AI'));
    expect(kPrivacyText, contains('LiveKit'));
    expect(kPrivacyText, contains('RevenueCat'));
    expect(kPrivacyText, contains('Sentry'));
    // data categories
    expect(kPrivacyText, contains('Facial analysis and physique'));
    expect(kPrivacyText, contains('Face data (biometric)'));
    expect(kPrivacyText, contains('voice sessions'));
    expect(kPrivacyText, contains('Approximate location'));
    // rights + retention
    expect(kPrivacyText, contains('Access and portability'));
    expect(kPrivacyText, contains('**Deletion has a 30-day recovery window**'));
    // no sale, children, transfers
    expect(kPrivacyText, contains('we do not sell your personal data'));
    // advertising + encryption, stated plainly and in bold
    expect(kPrivacyText, contains('## Advertising'));
    expect(kPrivacyText, contains('**No ads are shown in the current version'));
    expect(kPrivacyText, contains('**Ayma is not end-to-end encrypted.**'));
    expect(kPrivacyText, isNot(contains('Internal note')));
    expect(kPrivacyText, isNot(contains('|')));
    expect(kPrivacyText, contains('18 and over'));
    expect(kPrivacyText, contains('International data transfers'));
  });

  test('kPrivacyText is dated today and has no unresolved placeholders', () {
    expect(kPrivacyText, contains('_Last updated: 2026-10-25_'));
    expect(kPrivacyText, isNot(contains('PLACEHOLDER')));
  });

  // Regression (N6): the user-facing policy must not leak the internal
  // drafting / attorney-review reminders that lived in the source as
  // `> **Note:** …` blockquotes. Every one of these phrases was once rendered
  // to users; none may ever render again.
  test('kPrivacyText contains no internal drafting notes', () {
    expect(kPrivacyText, isNot(contains('**Note:**')));
    expect(kPrivacyText, isNot(contains('EU/UK representative')));
    expect(kPrivacyText, isNot(contains('Confirm this list before launch')));
    expect(kPrivacyText, isNot(contains('Align this section with the App')));
    expect(kPrivacyText, isNot(contains('transfer mechanism relied on')));
    expect(kPrivacyText, isNot(contains('Insert concrete backup rotation')));
    expect(kPrivacyText, isNot(contains('add the postal address')));
    expect(kPrivacyText, isNot(contains('Attorney review')));
  });

  testWidgets('the rendered Privacy screen shows no drafting notes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();

    final text = _plain(tester);
    expect(text, isNot(contains('Note:')));
    expect(text, isNot(contains('EU/UK representative')));
    expect(text, isNot(contains('before launch')));
    expect(text, isNot(contains('Attorney review')));
  });
}
