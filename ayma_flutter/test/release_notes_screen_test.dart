import 'package:ayma_flutter/release_notes.dart';
import 'package:ayma_flutter/screens/release_notes_screen.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flattens every RichText on screen to its plain string.
String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rt) => rt.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('renders the current version heading and a known bullet',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: const ReleaseNotesScreen(),
    ));
    await tester.pumpAndSettle();

    final text = _plain(tester);
    expect(text, contains('$kReleaseNotesVersion — 11 Sep 2026'));
    expect(text, contains('"Search again" refresh action'));
  });

  test('kReleaseNotes is newest-first and covers earlier versions', () {
    expect(kReleaseNotesVersion, '1.10.1');
    expect(kReleaseNotes.indexOf('## 1.10.1'),
        lessThan(kReleaseNotes.indexOf('## 1.10.0')));
    expect(kReleaseNotes.indexOf('## 1.10.0'),
        lessThan(kReleaseNotes.indexOf('## 1.6.0')));
    expect(kReleaseNotes.indexOf('## 1.6.0'),
        lessThan(kReleaseNotes.indexOf('## 1.5.0')));
    expect(kReleaseNotes, contains('## 1.1.0'));
    expect(kReleaseNotes, contains('Full Terms of Service and a new Privacy Policy.'));
  });
}
