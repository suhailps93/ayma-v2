import 'dart:convert';

import 'package:ayma_flutter/screens/feedback_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/keyboard_dismiss.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Founder issue (iPhone testers): "no way to exit the keyboard". The
/// app-root [KeyboardDismissOnTap] must dismiss on taps over non-interactive
/// space — and, just as important, must provably never break the taps that
/// were already there (it's a raw-pointer [Listener], not a gesture-arena
/// competitor; these tests pin both halves of that contract).
void main() {
  Widget host({
    required FocusNode fieldA,
    required FocusNode fieldB,
    required VoidCallback onButton,
    required VoidCallback onKeepButton,
  }) {
    // Mirrors production wiring: KeyboardDismissOnTap installed once via the
    // MaterialApp `builder`, above the whole Navigator (main.dart).
    return MaterialApp(
      theme: AymaTheme.light,
      builder: (context, child) =>
          KeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: Column(
          children: [
            TextField(key: const Key('fieldA'), focusNode: fieldA),
            TextField(key: const Key('fieldB'), focusNode: fieldB),
            ElevatedButton(
              key: const Key('plainButton'),
              onPressed: onButton,
              child: const Text('PLAIN'),
            ),
            // Stand-in for the chat/DM composer bar.
            KeepKeyboardOnTap(
              child: ElevatedButton(
                key: const Key('keepButton'),
                onPressed: onKeepButton,
                child: const Text('KEEP'),
              ),
            ),
            const Expanded(child: SizedBox.expand(key: Key('emptySpace'))),
          ],
        ),
      ),
    );
  }

  testWidgets('tap on empty space unfocuses the text field', (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(host(
        fieldA: a, fieldB: b, onButton: () {}, onKeepButton: () {}));

    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();
    expect(a.hasFocus, isTrue);

    await tester.tap(find.byKey(const Key('emptySpace')));
    await tester.pump();
    expect(a.hasFocus, isFalse);
  });

  testWidgets('tapping the focused field itself keeps the keyboard',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(host(
        fieldA: a, fieldB: b, onButton: () {}, onKeepButton: () {}));

    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();
    expect(a.hasFocus, isTrue);
  });

  testWidgets('tapping another field hands focus over (no blank unfocus)',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(host(
        fieldA: a, fieldB: b, onButton: () {}, onKeepButton: () {}));

    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('fieldB')));
    await tester.pump();
    expect(b.hasFocus, isTrue);
    expect(a.hasFocus, isFalse);
  });

  testWidgets('buttons still receive their taps (and the keyboard drops)',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    var pressed = 0;
    await tester.pumpWidget(host(
        fieldA: a, fieldB: b, onButton: () => pressed++, onKeepButton: () {}));

    // Sanity without any focus: the wrapper must be a pure pass-through.
    await tester.tap(find.byKey(const Key('plainButton')));
    await tester.pump();
    expect(pressed, 1);

    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('plainButton')));
    await tester.pump();
    expect(pressed, 2, reason: 'the root Listener must never steal a tap');
    expect(a.hasFocus, isFalse,
        reason: 'a tap on a non-text control still puts the keyboard away');
  });

  testWidgets('KeepKeyboardOnTap region: button fires AND keyboard stays',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    var kept = 0;
    await tester.pumpWidget(host(
        fieldA: a, fieldB: b, onButton: () {}, onKeepButton: () => kept++));

    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('keepButton')));
    await tester.pump();
    expect(kept, 1);
    expect(a.hasFocus, isTrue,
        reason: 'composer-style regions must not bounce the keyboard');
  });

  testWidgets('a drag is not a tap: focus survives scroll-like gestures',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(host(
        fieldA: a, fieldB: b, onButton: () {}, onKeepButton: () {}));

    await tester.tap(find.byKey(const Key('fieldA')));
    await tester.pump();

    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(const Key('emptySpace'))));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(a.hasFocus, isTrue,
        reason: 'drag-dismiss belongs to the scrollables that opt into '
            'keyboardDismissBehavior.onDrag, not to the tap catcher');
  });

  testWidgets('forms with text fields scroll-dismiss the keyboard (onDrag)',
      (tester) async {
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient(
        (req) async => http.Response(jsonEncode({'ok': true}), 200),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: FeedbackScreen(api: api),
    ));
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.keyboardDismissBehavior,
        ScrollViewKeyboardDismissBehavior.onDrag);
  });
}
