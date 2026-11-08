import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduction attempts for AYMA-FLUTTER-3S:
/// "RawTooltipState is a SingleTickerProviderStateMixin but multiple
/// tickers were created" — 2 events, Nov 6 2026 21:40 PT, founder Pixel,
/// build 2327, inside the FLUTTER-3R semantics-storm window. The Sentry
/// stack is a pointer-down event reaching RawTooltipState's global
/// pointer handler, which lazily creates the tooltip's animation
/// controller — and the framework refuses because a ticker already
/// exists on that state. Each scenario drives one plausible sequence
/// and fails if that sequence throws the double-ticker error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app({required Widget child, Key? key}) {
    return MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );
  }

  dynamic takeError(WidgetTester tester) => tester.takeException();

  testWidgets('show then dismiss then tap elsewhere', (tester) async {
    await tester.pumpWidget(app(
      child: const Tooltip(message: 'Mute', child: Icon(Icons.mic)),
    ));
    await tester.longPress(find.byType(Tooltip));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    // Tap elsewhere to dismiss, then tap again.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
  });

  testWidgets('show then rebuild with new message while showing',
      (tester) async {
    var message = 'Mute';
    await tester.pumpWidget(app(
      child: StatefulBuilder(
        builder: (context, setState) => Tooltip(
          message: message,
          child: TextButton(
            onPressed: () => setState(() => message = 'Unmute'),
            child: const Text('tap'),
          ),
        ),
      ),
    ));
    await tester.longPress(find.byType(Tooltip));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.tap(find.text('tap'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
  });

  testWidgets('show then remove from tree while showing, then tap',
      (tester) async {
    var showTooltip = true;
    await tester.pumpWidget(app(
      child: StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            if (showTooltip)
              const Tooltip(message: 'One', child: Icon(Icons.star)),
            const Tooltip(message: 'Two', child: Icon(Icons.favorite)),
            TextButton(
              onPressed: () => setState(() => showTooltip = false),
              child: const Text('remove'),
            ),
          ],
        ),
      ),
    ));
    await tester.longPress(find.byIcon(Icons.star));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.tap(find.text('remove'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
  });

  testWidgets('manual trigger tooltip tapped repeatedly (tab-bar pattern)',
      (tester) async {
    await tester.pumpWidget(app(
      child: const Tooltip(
        message: 'Hold 1s for voice',
        triggerMode: TooltipTriggerMode.manual,
        child: Icon(Icons.mic),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
    }
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 200));
    expect(takeError(tester), isNull);
  });

  testWidgets('two tooltips: show first, tap second child', (tester) async {
    await tester.pumpWidget(app(
      child: const Row(
        children: [
          Tooltip(message: 'One', child: Icon(Icons.star)),
          Tooltip(message: 'Two', child: Icon(Icons.favorite)),
        ],
      ),
    ));
    await tester.longPress(find.byIcon(Icons.star));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.tap(find.byIcon(Icons.favorite));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
  });

  testWidgets('show, background/foreground, then tap', (tester) async {
    await tester.pumpWidget(app(
      child: const Tooltip(message: 'Mute', child: Icon(Icons.mic)),
    ));
    await tester.longPress(find.byType(Tooltip));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
  });

  testWidgets('tooltip in scrolling list, scrolled out and back',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          itemCount: 30,
          itemBuilder: (context, i) => Tooltip(
            message: 'Item $i',
            child: SizedBox(height: 80, child: Text('row $i')),
          ),
        ),
      ),
    ));
    await tester.longPress(find.text('row 0'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 2000);
    await tester.pumpAndSettle();
    expect(takeError(tester), isNull);
    await tester.fling(find.byType(ListView), const Offset(0, 2000), 2000);
    await tester.pumpAndSettle();
    expect(takeError(tester), isNull);
    await tester.longPress(find.text('row 0'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(takeError(tester), isNull);
  });
}
