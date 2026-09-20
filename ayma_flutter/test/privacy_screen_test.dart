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
  });

  test('kPrivacyText covers the disclosed points', () {
    // subprocessors
    expect(kPrivacyText, contains('Google Firebase'));
    expect(kPrivacyText, contains('Google Gemini / Vertex AI'));
    expect(kPrivacyText, contains('LiveKit'));
    // data categories
    expect(kPrivacyText, contains('facial analysis and physique'));
    expect(kPrivacyText, contains('voice sessions'));
    expect(kPrivacyText, contains('Approximate location'));
    // rights + retention
    expect(kPrivacyText, contains('Access and portability'));
    expect(kPrivacyText, contains('short recovery window'));
    // no sale, children, transfers
    expect(kPrivacyText, contains('We do not sell your personal data'));
    expect(kPrivacyText, contains('18 and over'));
    expect(kPrivacyText, contains('International data transfers'));
  });

  test('kPrivacyText is dated today and has no unresolved placeholders', () {
    expect(kPrivacyText, contains('_Last updated: 2026-09-17_'));
    expect(kPrivacyText, isNot(contains('PLACEHOLDER')));
  });
}
