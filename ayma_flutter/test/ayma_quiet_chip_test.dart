import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_quiet_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A lightweight theme carrying the two things the Unmute button's geometry
/// depends on: the Ayma tokens (so `context.ac` resolves) and the app's real
/// `textButtonTheme` minimum of (0, 44) — the floor defect 43 restores by
/// removing the compact density. Avoids [AymaTheme.dark], which pulls in
/// google_fonts.
ThemeData _theme(AymaTokens tokens) => ThemeData(
      extensions: [tokens],
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
    );

Future<void> _pump(
  WidgetTester tester, {
  required AymaTokens tokens,
  VoidCallback? onUnmute,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: _theme(tokens),
        home: Scaffold(
          body: Center(
            child: AymaQuietChip(onUnmute: onUnmute ?? () {}),
          ),
        ),
      ),
    );

void main() {
  for (final entry in {
    'dark': AymaTokens.dark,
    'light': AymaTokens.light,
  }.entries) {
    testWidgets('Unmute clears the 44 touch floor — ${entry.key}',
        (tester) async {
      await _pump(tester, tokens: entry.value);
      // Defect 43: `visualDensity: VisualDensity.compact` removed. With the
      // compact adjustment (-8) gone, the theme minimumSize (0, 44) renders at
      // the floor (the padded tap target carries it to 48); with compact it
      // rendered 36. Asserting >= 44 proves the density removal.
      final size = tester.getSize(find.widgetWithText(TextButton, 'Unmute'));
      expect(size.height, greaterThanOrEqualTo(44.0));
    });
  }

  testWidgets('quiet chip renders Unmute without overflow', (tester) async {
    await _pump(tester, tokens: AymaTokens.dark);
    expect(find.widgetWithText(TextButton, 'Unmute'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Unmute fires onUnmute', (tester) async {
    var tapped = false;
    await _pump(tester, tokens: AymaTokens.dark, onUnmute: () => tapped = true);
    await tester.tap(find.widgetWithText(TextButton, 'Unmute'));
    await tester.pump();
    expect(tapped, isTrue);
  });
}
