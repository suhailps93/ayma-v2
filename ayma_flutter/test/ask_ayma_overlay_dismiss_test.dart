// Tap-outside dismiss against the REAL production wiring (`showAskAymaOverlay`
// hosting a real `ChatScreen`), not just the generic chrome test in
// `ayma_chat_modal_test.dart`. Drag-down dismiss against real production
// wiring is already covered for the orb launcher's presentation of the same
// shared modal in `global_ayma_launcher_test.dart` (`_closeSheet`); this file
// is the tap-outside counterpart for the Ask-Ayma presentation.
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('tapping outside the Ask-Ayma modal dismisses it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAskAymaOverlay(
              context,
              transcriptStore: TranscriptStore(),
              api: _FakeApi(),
              ctx: const AskAymaContext(
                pageId: 'career',
                selectedText: 'I lead the analytics team in Lisbon.',
                quoteText: 'I lead the analytics team in Lisbon.',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Ask Ayma'), findsOneWidget);

    // The scrim, well above the modal (which docks over roughly the bottom
    // 62% of the screen on open).
    await tester.tapAt(const Offset(40, 40));
    await tester.pumpAndSettle();

    expect(find.text('Ask Ayma'), findsNothing);
    // Back to the launching screen underneath.
    expect(find.text('open'), findsOneWidget);
  });
}
