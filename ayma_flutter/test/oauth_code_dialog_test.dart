import 'package:ayma_flutter/widgets/oauth_code_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the shared OAuth "paste the redirect URL back" dialog.
Future<void> _openDialog(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => promptForOAuthCode(ctx),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('both action TextButtons render at least 44 tall (jobs defect 9)',
      (tester) async {
    await _openDialog(tester);

    for (final label in const ['Cancel', 'Connect']) {
      final size = tester.getSize(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(TextButton),
        ),
      );
      // The job floor is 44; Material 3 pads the tap target to 48. Assert the
      // floor and record that the rendered target meets the fuller 48.
      expect(size.height, greaterThanOrEqualTo(44),
          reason: '$label TextButton must clear the 44 min touch target');
      expect(size.height, 48,
          reason: '$label renders the M3 48 padded tap target');
    }
  });

  testWidgets('field and hint are present and the dialog is intact',
      (tester) async {
    await _openDialog(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Finish connecting'), findsOneWidget);
    // Hint legibility is a render-time property; presence of the field with
    // its decoration is what a widget test can assert.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, 'code=…');
    expect(field.autofocus, isTrue); // behavior unchanged
  });

  test('extractOAuthCode pulls the code param or returns bare input', () {
    expect(extractOAuthCode('https://x/cb?code=abc123&state=s'), 'abc123');
    expect(extractOAuthCode('  rawcode  '), 'rawcode');
  });
}
