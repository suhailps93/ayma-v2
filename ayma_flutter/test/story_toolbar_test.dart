import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/story_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool isPrivate,
  VoidCallback? onMakePublic,
  VoidCallback? onMakePrivate,
  VoidCallback? onAsk,
}) {
  return tester.pumpWidget(MaterialApp(
    theme: AymaTheme.light,
    home: Scaffold(
      body: StoryToolbar(
        anchor: const Offset(100, 300),
        isPrivate: isPrivate,
        busy: false,
        onMakePublic: onMakePublic ?? () {},
        onMakePrivate: onMakePrivate ?? () {},
        onAsk: onAsk ?? () {},
        onDismiss: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('an already-public sentence shows only Make private + Ask Ayma',
      (tester) async {
    await _pump(tester, isPrivate: false);
    await tester.pump();

    expect(find.text('Make private'), findsOneWidget);
    expect(find.text('Ask Ayma'), findsOneWidget);
    expect(find.text('Make public'), findsNothing);
  });

  testWidgets('an already-private sentence shows only Make public + Ask Ayma',
      (tester) async {
    await _pump(tester, isPrivate: true);
    await tester.pump();

    expect(find.text('Make public'), findsOneWidget);
    expect(find.text('Ask Ayma'), findsOneWidget);
    expect(find.text('Make private'), findsNothing);
  });

  testWidgets('tapping the remaining privacy action calls the right callback',
      (tester) async {
    var madePublicCalled = false;
    var madePrivateCalled = false;
    await _pump(
      tester,
      isPrivate: true,
      onMakePublic: () => madePublicCalled = true,
      onMakePrivate: () => madePrivateCalled = true,
    );
    await tester.pump();

    await tester.tap(find.text('Make public'));
    await tester.pump();

    expect(madePublicCalled, isTrue);
    expect(madePrivateCalled, isFalse);
  });

  testWidgets('tapping Ask Ayma calls onAsk regardless of privacy state',
      (tester) async {
    var asked = false;
    await _pump(tester, isPrivate: false, onAsk: () => asked = true);
    await tester.pump();

    await tester.tap(find.text('Ask Ayma'));
    await tester.pump();

    expect(asked, isTrue);
  });

  testWidgets('no checked-dot affordance renders on either item',
      (tester) async {
    await _pump(tester, isPrivate: false);
    await tester.pump();

    // The old three-item toolbar drew a small circular dot beneath whichever
    // action was "checked". With only one privacy action ever shown, that
    // affordance no longer makes sense — assert the toolbar card doesn't
    // contain any decorated circle container.
    final circles = tester.widgetList<Container>(find.byType(Container)).where(
        (c) => c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).shape == BoxShape.circle);
    expect(circles, isEmpty);
  });
}
