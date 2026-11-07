import 'package:ayma_flutter/screens/ayma_keyboard_screen.dart';
import 'package:ayma_flutter/services/keyboard_draft_store.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/send_to_keyboard_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: child,
    );

void main() {
  testWidgets('explainer states the privacy posture and enable actions',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(const AymaKeyboardScreen()));
    await tester.pump();
    expect(find.text('Ayma Keyboard'), findsOneWidget);
    expect(find.textContaining('never logs, stores, or sends'), findsOneWidget);
    expect(find.textContaining('makes no network calls'), findsOneWidget);
    expect(find.textContaining('Password fields get nothing'), findsOneWidget);
    expect(find.textContaining('never types on her own'), findsOneWidget);
    expect(find.byKey(const ValueKey('ayma-keyboard-enable')), findsOneWidget);
    expect(find.byKey(const ValueKey('ayma-keyboard-switch')), findsOneWidget);
  });

  testWidgets('Send to Ayma Keyboard stores the draft text', (tester) async {
    String? storedText;
    const channel = MethodChannel('test/keyboard_button');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setDraft') {
        storedText = (call.arguments as Map)['text'] as String;
        return true;
      }
      if (call.method == 'getDraft') {
        return storedText == null
            ? null
            : KeyboardDraft(text: storedText!, createdAtMillis: 1).encode();
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final service = KeyboardDraftService(channel: channel);
    await tester.pumpWidget(
      _wrap(Scaffold(
          body: SendToKeyboardButton(
              text: 'a drafted reply', service: service))),
    );
    await tester.tap(find.byKey(const ValueKey('send-to-ayma-keyboard')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(storedText, 'a drafted reply');
  });
}
