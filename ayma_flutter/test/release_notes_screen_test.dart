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
    expect(text, contains('$kReleaseNotesVersion — 15 Sep 2026'));
    expect(text, contains('Tap any sentence'));
  });

  test('kReleaseNotes is newest-first and covers earlier versions', () {
    // kReleaseNotesVersion must always match the heading that actually leads
    // kReleaseNotes, not a literal copied in by hand — a hardcoded version
    // string here just goes stale the next time either constant is bumped.
    final headingVersion =
        RegExp(r'^## (\S+)', multiLine: true).firstMatch(kReleaseNotes)?.group(1);
    expect(headingVersion, kReleaseNotesVersion);
    expect(kReleaseNotes.indexOf('## 1.24.0'),
        lessThan(kReleaseNotes.indexOf('## 1.23.0')));
    expect(kReleaseNotes.indexOf('## 1.23.0'),
        lessThan(kReleaseNotes.indexOf('## 1.22.1')));
    expect(kReleaseNotes.indexOf('## 1.22.1'),
        lessThan(kReleaseNotes.indexOf('## 1.22.0')));
    expect(kReleaseNotes.indexOf('## 1.22.0'),
        lessThan(kReleaseNotes.indexOf('## 1.21.1')));
    expect(kReleaseNotes.indexOf('## 1.21.1'),
        lessThan(kReleaseNotes.indexOf('## 1.21.0')));
    expect(kReleaseNotes.indexOf('## 1.21.0'),
        lessThan(kReleaseNotes.indexOf('## 1.20.0')));
    expect(kReleaseNotes.indexOf('## 1.20.0'),
        lessThan(kReleaseNotes.indexOf('## 1.19.1')));
    expect(kReleaseNotes.indexOf('## 1.19.1'),
        lessThan(kReleaseNotes.indexOf('## 1.19.0')));
    expect(kReleaseNotes.indexOf('## 1.19.0'),
        lessThan(kReleaseNotes.indexOf('## 1.18.0')));
    expect(kReleaseNotes.indexOf('## 1.18.0'),
        lessThan(kReleaseNotes.indexOf('## 1.17.0')));
    expect(kReleaseNotes.indexOf('## 1.17.0'),
        lessThan(kReleaseNotes.indexOf('## 1.16.0')));
    expect(kReleaseNotes.indexOf('## 1.16.0'),
        lessThan(kReleaseNotes.indexOf('## 1.15.0')));
    expect(kReleaseNotes.indexOf('## 1.15.0'),
        lessThan(kReleaseNotes.indexOf('## 1.14.0')));
    expect(kReleaseNotes.indexOf('## 1.14.0'),
        lessThan(kReleaseNotes.indexOf('## 1.13.0')));
    expect(kReleaseNotes.indexOf('## 1.13.0'),
        lessThan(kReleaseNotes.indexOf('## 1.12.0')));
    expect(kReleaseNotes.indexOf('## 1.12.0'),
        lessThan(kReleaseNotes.indexOf('## 1.11.0')));
    expect(kReleaseNotes.indexOf('## 1.11.0'),
        lessThan(kReleaseNotes.indexOf('## 1.10.1')));
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
