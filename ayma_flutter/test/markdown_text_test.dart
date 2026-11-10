import 'package:ayma_flutter/theme.dart';
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

  testWidgets('a wrapped list item keeps its continuation and bold across it',
      (tester) async {
    await _pump(tester, '- **first part\n  still bold** tail\n- second');
    final text = _plain(tester);
    expect(text, contains('first part still bold tail'));
    expect(text, isNot(contains('**')));
    final bold = <String?>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.w700) {
          bold.add(span.text);
        }
        return true;
      });
    }
    expect(bold, contains('first part still bold'));
    expect('•'.allMatches(text).length, 2);
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

  // --- fenced code blocks (founder tree-diagram bug) -----------------------

  // The exact shape from the founder's transcript: a box-drawing ASCII tree
  // inside a ``` fence.
  const tree = '```\n'
      '                MY LIFE\n'
      '                   │\n'
      '    ┌──────────────┼──────────────┐\n'
      '    │              │              │\n'
      ' CAREER         FAMILY         GROWTH\n'
      '```';

  Text codeText(WidgetTester tester) => tester.widget<Text>(find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Text),
      ));

  testWidgets('a fenced block renders mono, verbatim, without the fences',
      (tester) async {
    await _pump(tester, 'here you go:\n\n$tree\n\nlike it?');
    final text = codeText(tester);
    // Fences stripped, box-drawing content kept exactly — leading whitespace
    // and line breaks included.
    expect(text.data, isNot(contains('```')));
    expect(text.data, contains('                MY LIFE'));
    expect(text.data,
        contains('    ┌──────────────┼──────────────┐'));
    expect(text.data, contains(' CAREER         FAMILY         GROWTH'));
    // The app's mono face (JetBrains Mono), not the surrounding body font.
    expect(text.style?.fontFamily,
        AymaType.mono(weight: FontWeight.w400).fontFamily);
    // Surrounding prose still renders as normal paragraphs.
    final all = _plain(tester);
    expect(all, contains('here you go:'));
    expect(all, contains('like it?'));
  });

  testWidgets('a fenced block never wraps mid-token — it scrolls horizontally',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200, // narrower than the tree — would force wrapping
            child: MarkdownText(tree, style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
    final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView));
    expect(scroll.scrollDirection, Axis.horizontal);
    expect(codeText(tester).softWrap, isFalse);
  });

  testWidgets('a fenced block gets a card background with rounded corners',
      (tester) async {
    await _pump(tester, tree);
    final container = tester.widget<Container>(find.ancestor(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Container),
    ).first);
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, isNotNull);
    expect(deco.borderRadius, isNotNull);
    expect(container.padding, isNotNull);
  });

  testWidgets('a language tag on the fence is dropped', (tester) async {
    await _pump(tester, '```text\nplain contents\n```');
    final text = codeText(tester);
    expect(text.data, 'plain contents');
  });

  testWidgets('an unclosed fence still renders as a code block',
      (tester) async {
    await _pump(tester, 'oops:\n```\nA\n └─ B');
    final text = codeText(tester);
    expect(text.data, 'A\n └─ B');
    expect(_plain(tester), isNot(contains('```')));
  });

  testWidgets('inline code renders in the mono face with a faint background',
      (tester) async {
    // A colored style, the way chat_screen always passes one — the faint
    // wash is derived from the surrounding text colour.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownText('run `flutter test` now',
              style: const TextStyle(fontSize: 14, color: Colors.black)),
        ),
      ),
    );
    TextSpan? code;
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      (rt.text as TextSpan).visitChildren((s) {
        if (s is TextSpan && s.text == 'flutter test') code = s;
        return true;
      });
    }
    expect(code, isNotNull);
    expect(code!.style?.fontFamily,
        AymaType.mono(weight: FontWeight.w400).fontFamily);
    expect(code!.style?.backgroundColor, isNotNull);
  });

  // R1 — list-item gap is on the 4pt fine grid (was 3, off-grid). The gap is
  // the bottom padding wrapping each list-item Row; it renders 4 in both
  // themes (the value is theme-independent, asserted under both for parity).
  // The AymaTokens extension is injected directly (not the full AymaTheme,
  // whose serif textTheme would try to fetch a web font in tests).
  for (final theme in <(String, AymaTokens)>[
    ('light', AymaTokens.light),
    ('dark', AymaTokens.dark),
  ]) {
    final (name, tokens) = theme;
    testWidgets('R1: list-item bottom gap renders 4, never 3 ($name)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [tokens]),
        home: Scaffold(
          body: MarkdownText('- one\n- two\n- three',
              style: const TextStyle(fontSize: 14)),
        ),
      ));
      final gaps = tester
          .widgetList<Padding>(find.byType(Padding))
          .map((p) => p.padding)
          .whereType<EdgeInsets>()
          .where((e) => e.bottom > 0 && e.left == 0 && e.top == 0 && e.right == 0)
          .toList();
      // Every list-item wrapper uses bottom:4; none remain at the old 3.
      expect(gaps.where((e) => e.bottom == 4), isNotEmpty,
          reason: 'list items wrap in EdgeInsets.only(bottom: 4)');
      expect(gaps.where((e) => e.bottom == 3), isEmpty,
          reason: 'no list item keeps the old off-grid 3pt gap');
    });
  }

  // R5 — the MarkdownText DEFAULT link (no explicit linkColor) renders through
  // the text-safe linkText token, not the raw AymaColors.link, in both themes.
  for (final theme in <(String, AymaTokens)>[
    ('light', AymaTokens.light),
    ('dark', AymaTokens.dark),
  ]) {
    final (name, tokens) = theme;
    testWidgets('R5: default link renders through linkText, not raw link '
        '($name)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [tokens]),
        home: Scaffold(
          body: MarkdownText('see [the docs](https://example.com) here',
              style: const TextStyle(fontSize: 14)),
        ),
      ));
      TextSpan? linkSpan;
      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        (rt.text as TextSpan).visitChildren((s) {
          if (s is TextSpan && s.text == 'the docs') linkSpan = s;
          return true;
        });
      }
      expect(linkSpan, isNotNull, reason: 'link text span rendered');
      expect(linkSpan!.style?.color, tokens.linkText,
          reason: 'default link uses the derived linkText token');
      expect(linkSpan!.style?.color, isNot(AymaColors.link),
          reason: 'default link is NOT the raw (failing) link blue');
      expect(linkSpan!.style?.decoration, TextDecoration.underline);
    });
  }

  // R5 — an explicit linkColor (e.g. chat passes accentText) still wins over
  // the linkText default: the override path is unchanged.
  testWidgets('R5: explicit linkColor overrides the linkText default',
      (tester) async {
    const override = Color(0xFF123456);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [AymaTokens.dark]),
      home: Scaffold(
        body: MarkdownText('a [link](https://x.com) b',
            style: const TextStyle(fontSize: 14), linkColor: override),
      ),
    ));
    TextSpan? linkSpan;
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      (rt.text as TextSpan).visitChildren((s) {
        if (s is TextSpan && s.text == 'link') linkSpan = s;
        return true;
      });
    }
    expect(linkSpan?.style?.color, override,
        reason: 'explicit linkColor is respected, default not applied');
  });
}
