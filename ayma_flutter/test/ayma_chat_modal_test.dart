// The ONE shared dockable-chat-modal chrome (`showAymaChatModal`,
// `ayma_chat_modal.dart`) — the treatment both the floating Ayma orb launcher
// and every "tap to correct" affordance (`showAskAymaOverlay`) now open.
// Exercised here directly, against a minimal placeholder child, so its two
// dismiss mechanisms are each proven once at the source instead of being
// re-tested (or, worse, silently left untested) per caller. Real-caller
// coverage of the same mechanisms against production wiring lives in
// `global_ayma_launcher_test.dart` (drag-down) and
// `ask_ayma_overlay_dismiss_test.dart` (tap-outside).
import 'package:ayma_flutter/widgets/ayma_chat_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder _handle() => find.byKey(const ValueKey('aymaChatModalHandle'));

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showAymaChatModal(
            context,
            builder: (_) => const Center(child: Text('modal content')),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('opens docked over most of the screen, not a small sheet',
      (tester) async {
    await _open(tester);
    final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final sheetTop = tester.getTopLeft(_handle()).dy;
    // Opens at initialChildSize 0.62 — well over half the screen, nowhere
    // near a small bottom-sheet-style peek.
    expect(sheetTop, lessThan(screenHeight * 0.5));
  });

  testWidgets('tapping outside the sheet dismisses it', (tester) async {
    await _open(tester);
    expect(find.text('modal content'), findsOneWidget);

    // The scrim above the sheet (which opens around 62% of the screen) —
    // nowhere near the sheet's own content.
    await tester.tapAt(const Offset(40, 40));
    await tester.pumpAndSettle();

    expect(find.text('modal content'), findsNothing);
  });

  testWidgets(
      'dragging the handle down past the minimum size dismisses it',
      (tester) async {
    await _open(tester);
    expect(find.text('modal content'), findsOneWidget);

    await tester.drag(_handle(), const Offset(0, 700));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('modal content'), findsNothing);
  });

  testWidgets(
      'dragging the handle up expands the sheet instead of dismissing it',
      (tester) async {
    await _open(tester);
    final before = tester.getTopLeft(_handle()).dy;

    await tester.drag(_handle(), const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Still open — a drag toward maxChildSize is a resize, not a dismiss.
    expect(find.text('modal content'), findsOneWidget);
    final after = tester.getTopLeft(_handle()).dy;
    // The sheet grew: its top edge moved further up the screen.
    expect(after, lessThan(before));
  });

  testWidgets('a small drag that stays above the minimum size keeps it open',
      (tester) async {
    await _open(tester);

    await tester.drag(_handle(), const Offset(0, 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('modal content'), findsOneWidget);

    // Clean up so this doesn't bleed a live route into another test file
    // sharing the same process.
    await tester.drag(_handle(), const Offset(0, 700));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
      'a composer pinned to the bottom of the embedded content stays above '
      'a simulated keyboard inset',
      (tester) async {
    const keyboardHeight = 300.0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAymaChatModal(
              context,
              // Mirrors the shape every real caller embeds: a scrollable
              // area on top, a composer-like field pinned to the very
              // bottom via a `Column` — exactly where `ChatScreen`'s own
              // `_Composer` sits.
              builder: (_) => const Column(
                children: [
                  Expanded(child: Center(child: Text('transcript'))),
                  TextField(key: ValueKey('composer')),
                ],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Simulate the keyboard opening — `MediaQuery.viewInsets.bottom` is what
    // the framework sets in production once a text field gains focus.
    final view = tester.view;
    view.viewInsets = FakeViewPadding(bottom: keyboardHeight * view.devicePixelRatio);
    addTearDown(view.resetViewInsets);
    await tester.pump();

    final screenHeight = view.physicalSize.height / view.devicePixelRatio;
    final composerBottom =
        tester.getBottomLeft(find.byKey(const ValueKey('composer'))).dy;
    // The composer must sit entirely above where the keyboard starts, not
    // behind it.
    expect(composerBottom, lessThanOrEqualTo(screenHeight - keyboardHeight));
  });
}
