import 'package:ayma_flutter/routing/entry.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('entryRouteFor maps every session_mode to a real screen path', () {
    expect(entryRouteFor('active'), MainShellScreen.path);
    expect(entryRouteFor('interview'), PreboardingFlowScreen.path);
    expect(entryRouteFor('marketing'), ChatScreen.path);
    expect(entryRouteFor('anything-else'), ChatScreen.path);
  });

  testWidgets('chat shell renders and accepts typed text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: ChatScreen()));

    expect(find.text('Say hello to start a conversation.'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello ayma');
    await tester.pump();
    expect(find.text('hello ayma'), findsOneWidget);

    // Step 14: the voice mic button is present in the composer.
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
  });

  testWidgets('preboarding flow starts on the name step with a gated Next',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: PreboardingFlowScreen()),
    );

    expect(find.text('About you (1/6)'), findsOneWidget);
    expect(find.text('What should Ayma call you?'), findsOneWidget);

    // With a name entered, Next moves to the birthdate step.
    await tester.enterText(find.byType(TextField), 'Alex');
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('About you (2/6)'), findsOneWidget);
    expect(find.textContaining('date of birth'), findsOneWidget);
  });
}
