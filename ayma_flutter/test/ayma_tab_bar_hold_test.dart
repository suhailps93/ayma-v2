// The orb tab's 1-second hold (voice entry point): a plain tap is unchanged,
// a full hold fires onOrbLongPress instead of onSelected, an early release is
// just a tap.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<int> selected;
  late int holds;

  Future<void> pumpBar(WidgetTester tester) async {
    selected = [];
    holds = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: -1,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ),
    );
  }

  testWidgets('a quick tap on the orb still selects tab 0', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byTooltip('Ayma'));
    await tester.pump();
    expect(selected, [0]);
    expect(holds, 0);
  });

  testWidgets('a 1s hold fires the long-press callback, not onSelected', (
    tester,
  ) async {
    await pumpBar(tester);
    final g = await tester.startGesture(
      tester.getCenter(find.byTooltip('Ayma')),
    );
    // The first frame only starts the ticker's clock.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(holds, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(holds, 1);
    await g.up();
    await tester.pump();
    expect(selected, isEmpty);
    expect(holds, 1);
  });

  testWidgets('releasing before 1s is a tap and never fires the hold', (
    tester,
  ) async {
    await pumpBar(tester);
    final g = await tester.startGesture(
      tester.getCenter(find.byTooltip('Ayma')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await g.up();
    await tester.pump(const Duration(seconds: 2));
    expect(selected, [0]);
    expect(holds, 0);
  });

  testWidgets('dragging off the orb cancels the hold', (tester) async {
    await pumpBar(tester);
    final g = await tester.startGesture(
      tester.getCenter(find.byTooltip('Ayma')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await g.moveBy(const Offset(0, -200));
    await tester.pump(const Duration(seconds: 3));
    await g.up();
    await tester.pump();
    expect(holds, 0);
    expect(selected, isEmpty);
  });
}
