import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/collapsible_message_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, String text) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CollapsibleMessageText(
              text,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );

/// Flattens every RichText on screen to its plain string.
String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rt) => (rt.text as TextSpan).toPlainText())
    .join('\n');

/// A long message shaped like the NOTE 144 self-check report: a short
/// header, then one very long single-line section, then a tail.
String _longMessage(int totalChars) {
  final head = 'SELF-CHECK — run test\n140 checks: 23 PASS\n\nFAILURES:\n'
      '• first failure — did not navigate\n• second failure — timed out\n';
  final tail = '\nTAIL-MARKER end of message.';
  final fillerLen = totalChars - head.length - tail.length;
  final filler = 'SKIPPED: ${'nav:item, ' * (fillerLen ~/ 10 + 1)}';
  return '$head${filler.substring(0, fillerLen)}$tail';
}

void main() {
  testWidgets('short message renders in full with no expander',
      (tester) async {
    await _pump(tester, 'Hey Daniel.');
    expect(find.textContaining('Show full message'), findsNothing);
    expect(find.textContaining('Show less'), findsNothing);
    expect(_plain(tester), contains('Hey Daniel.'));
  });

  testWidgets('message at the threshold renders in full with no expander',
      (tester) async {
    await _pump(tester, 'x' * CollapsibleMessageText.collapseThresholdChars);
    expect(find.textContaining('Show full message'), findsNothing);
  });

  testWidgets('over-long message collapses to a preview with an expander',
      (tester) async {
    final text = _longMessage(5728);
    await _pump(tester, text);
    // The tail marker is past the preview cut: not rendered collapsed.
    expect(_plain(tester), isNot(contains('TAIL-MARKER')));
    // The head is rendered.
    expect(_plain(tester), contains('FAILURES:'));
    // The expander names the full length.
    expect(find.textContaining('Show full message (${text.length} characters)'),
        findsOneWidget);
    // Collapsed render stays bounded: well under the full text.
    expect(_plain(tester).length,
        lessThan(CollapsibleMessageText.previewChars + 100));
  });

  testWidgets('tapping the expander shows the full message, then collapses',
      (tester) async {
    final text = _longMessage(2000);
    await _pump(tester, text);
    expect(_plain(tester), isNot(contains('TAIL-MARKER')));
    await tester.tap(find.textContaining('Show full message'));
    await tester.pump();
    expect(_plain(tester), contains('TAIL-MARKER'));
    expect(find.text('Show less'), findsOneWidget);
    // The expanded text pushes the button below the fold: scroll it into
    // view before tapping (the pump harness wraps the widget in a
    // SingleChildScrollView).
    await tester.ensureVisible(find.text('Show less'));
    await tester.pump();
    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(_plain(tester), isNot(contains('TAIL-MARKER')));
    expect(find.textContaining('Show full message'), findsOneWidget);
  });

  testWidgets('preview cuts at a line boundary, never mid-word when one fits',
      (tester) async {
    // A newline sits just before the preview cap (at ~1101): the preview
    // ends exactly there instead of mid-word. The marker line sits past
    // the cut, so it is excluded from the preview.
    final text =
        "${'A' * 100}\n${'word ' * 200}\n${'word ' * 100}\nTAIL-MARKER";
    final preview = CollapsibleMessageText.previewOf(text);
    expect(preview, isNot(contains('TAIL-MARKER')));
    expect(preview.endsWith('…'), isTrue);
    // Cut at the newline: 100 As + newline + 200 words = 1101 chars,
    // minus the trailing space trimRight drops, plus the ellipsis.
    expect(preview.length, 1101);
  });

  testWidgets('markdown still renders inside the collapsed preview',
      (tester) async {
    final text = 'A **bold** opener.\n${'filler sentence here. ' * 120}';
    await _pump(tester, text);
    expect(_plain(tester), contains('bold'));
    expect(_plain(tester), isNot(contains('**')));
  });

  testWidgets(
      'expander clears the 44 touch floor and labels in accentText',
      (tester) async {
    final text = _longMessage(2000);
    // The Ayma tokens (so `context.ac` resolves) plus the app's real
    // textButtonTheme minimum (0, 44) — the floor defect 45 restores by
    // dropping Size.zero + shrinkWrap. Kept off AymaTheme.dark (google_fonts).
    final theme = ThemeData(
      extensions: const [AymaTokens.dark],
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: CollapsibleMessageText(
              text,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    final btn = find.widgetWithText(
      TextButton,
      'Show full message (${text.length} characters)',
    );
    expect(btn, findsOneWidget);
    // Defect 45: `minimumSize: Size.zero` + `tapTargetSize: shrinkWrap`
    // removed, so the theme minimum (0, 44) governs (padded tap target 48);
    // with the overrides the button rendered ~26 tall.
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(44.0));
    // Defect 46: label routes through accentText (text-safe), not raw accent.
    final label = tester.widget<Text>(
      find.descendant(of: btn, matching: find.byType(Text)),
    );
    expect(label.style?.color, AymaTokens.dark.accentText);
  });
}
