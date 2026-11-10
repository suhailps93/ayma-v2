import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_action.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(ThemeData theme, Widget child) => MaterialApp(
        theme: theme,
        home: Scaffold(appBar: AppBar(actions: [child]), body: const SizedBox()),
      );

  testWidgets('defaults to the Ayma orb + "Ask Ayma" text', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      host(AymaTheme.dark, AskAymaAction(onPressed: () => tapped = true)),
    );

    expect(find.byType(AymaOrb), findsOneWidget);
    expect(find.text('Ask Ayma'), findsOneWidget);

    await tester.tap(find.byType(AskAymaAction));
    expect(tapped, isTrue);
  });

  testWidgets('supports a custom label while keeping the same icon',
      (tester) async {
    await tester.pumpWidget(
      host(
        AymaTheme.dark,
        AskAymaAction(label: 'Edit with Ayma', onPressed: () {}),
      ),
    );

    expect(find.byType(AymaOrb), findsOneWidget);
    expect(find.text('Edit with Ayma'), findsOneWidget);
  });

  testWidgets('renders without error in light and dark themes',
      (tester) async {
    for (final theme in [AymaTheme.light, AymaTheme.dark]) {
      await tester.pumpWidget(host(theme, AskAymaAction(onPressed: () {})));
      await tester.pump();
      expect(find.byType(AskAymaAction), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('renders at least the theme-minimum 44 tall and still taps',
      (tester) async {
    // The app theme sets TextButton minimumSize Size(0, 44) (token-followup,
    // cluster 12 R2). Assert the rendered height clears the 44 touch floor —
    // do NOT assume the raw M3 default (40). (M3's padded tap target may
    // render it at 48; either way it must clear 44.) Hosted in an
    // unconstrained body so the toolbar height can't cap it.
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AskAymaAction(onPressed: () => tapped = true),
          ),
        ),
      ),
    );
    await tester.pump();

    final height = tester.getSize(find.byType(TextButton)).height;
    expect(height, greaterThanOrEqualTo(44.0),
        reason: 'Ask-Ayma action must clear the 44 touch floor; was $height');

    await tester.tap(find.byType(AskAymaAction));
    expect(tapped, isTrue, reason: 'a tap still opens the scoped turn');
  });

  testWidgets('a null onPressed disables the button', (tester) async {
    await tester.pumpWidget(host(AymaTheme.dark, const AskAymaAction(onPressed: null)));

    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.onPressed, isNull);
  });
}
