import 'package:ayma_flutter/widgets/markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, String md) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownText(md, style: const TextStyle(fontSize: 14)),
        ),
      ),
    );

/// Flattens every RichText on screen to its plain string.
String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rt) => (rt.text as TextSpan).toPlainText())
    .join('\n');

void main() {
  testWidgets('renders bold / italic / code inline without the markers',
      (tester) async {
    await _pump(tester, 'a **bold** and *slanted* and `code` word');
    final text = _plain(tester);
    expect(text, contains('bold'));
    expect(text, contains('slanted'));
    expect(text, contains('code'));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('`')));
  });

  testWidgets('renders a bullet list with markers', (tester) async {
    await _pump(tester, 'here:\n- first\n- second');
    final text = _plain(tester);
    expect(text, contains('first'));
    expect(text, contains('second'));
    expect(text, contains('•'));
  });

  testWidgets('renders a numbered list keeping the numbers', (tester) async {
    await _pump(tester, '1. alpha\n2. beta');
    final text = _plain(tester);
    expect(text, contains('alpha'));
    expect(text, contains('beta'));
    expect(text, contains('1.'));
    expect(text, contains('2.'));
  });

  testWidgets('a link becomes tappable text without the URL syntax',
      (tester) async {
    await _pump(tester, 'see [the Roxie](https://roxie.com) tonight');
    final text = _plain(tester);
    expect(text, contains('the Roxie'));
    expect(text, isNot(contains('https://roxie.com')));
    expect(text, isNot(contains('](')));

    // the label span carries a tap recognizer
    final spans = <InlineSpan>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      (rt.text as TextSpan).visitChildren((s) {
        spans.add(s);
        return true;
      });
    }
    expect(
      spans.any((s) => s is TextSpan && s.recognizer is TapGestureRecognizer),
      isTrue,
    );
  });

  testWidgets('a stray asterisk is left as plain text', (tester) async {
    await _pump(tester, 'rating 4*/5, not bad');
    expect(_plain(tester), contains('4*/5'));
  });

  testWidgets('plain prose renders unchanged', (tester) async {
    await _pump(tester, 'just a normal sentence.');
    expect(_plain(tester), 'just a normal sentence.');
  });
}
