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

  testWidgets('a bare http(s) URL becomes tappable underlined text',
      (tester) async {
    await _pump(tester, 'book here https://example.com/x now');
    final text = _plain(tester);
    expect(text, contains('https://example.com/x'));

    final spans = <InlineSpan>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      (rt.text as TextSpan).visitChildren((s) {
        spans.add(s);
        return true;
      });
    }
    final linkSpan = spans.firstWhere(
      (s) =>
          s is TextSpan &&
          s.text == 'https://example.com/x' &&
          s.recognizer is TapGestureRecognizer,
      orElse: () => const TextSpan(),
    ) as TextSpan;
    expect(linkSpan.recognizer, isA<TapGestureRecognizer>());
    expect(linkSpan.style?.decoration, TextDecoration.underline);
  });

  testWidgets('a trailing period is not swallowed into the link',
      (tester) async {
    await _pump(tester, 'see https://a.com/b.');
    final spans = <InlineSpan>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      (rt.text as TextSpan).visitChildren((s) {
        spans.add(s);
        return true;
      });
    }
    final tapText = spans
        .whereType<TextSpan>()
        .where((s) => s.recognizer is TapGestureRecognizer)
        .map((s) => s.text)
        .toList();
    expect(tapText, contains('https://a.com/b'));
    expect(tapText, isNot(contains('https://a.com/b.')));
    // the period is still shown, just outside the tap target
    expect(_plain(tester), contains('https://a.com/b.'));
  });

  testWidgets('an explicit [label](url) link still shows its label, not the url',
      (tester) async {
    await _pump(tester, 'see [the Roxie](https://roxie.com) tonight');
    final text = _plain(tester);
    expect(text, contains('the Roxie'));
    expect(text, isNot(contains('https://roxie.com')));
  });

  testWidgets('a bare URL inside a bullet list item is linkified',
      (tester) async {
    await _pump(tester, 'links:\n- https://example.com/one\n- other');
    final spans = <InlineSpan>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      (rt.text as TextSpan).visitChildren((s) {
        spans.add(s);
        return true;
      });
    }
    expect(
      spans.any((s) =>
          s is TextSpan &&
          s.text == 'https://example.com/one' &&
          s.recognizer is TapGestureRecognizer),
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
