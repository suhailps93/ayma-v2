// D13: ONE chat — a scoped Ask-Ayma turn IS the main chat conversation: the
// exchange lands in the main history, the bottom nav bar stays visible, and
// a second orb tap expands the sheet to the full chat (never voice from a
// scoped turn — the voice agent doesn't bind its correction tools; scoped
// voice stays push-to-talk via the mic button). Founder refinement (Nov
// 2026): the PARTIAL sheet lists no history — context card, chips and
// composer only; expanding reveals the whole conversation.
import 'package:ayma_flutter/models/living_report.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _navBarCopy = ValueKey('aymaChatModalNavBar');

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  @override
  Future<ReportCorrectResult> correctReport(
    String reportType,
    String reportId, {
    required List<String> blockIds,
    required String scope,
    required String message,
  }) async {
    return ReportCorrectResult(
      ok: true,
      results: [
        ReportCorrectItem(blockId: blockIds.first, ok: true, reply: 'Done — removed.'),
      ],
    );
  }
}

const _ctx = AskAymaContext(
  origin: AskAymaOrigin.report,
  reportType: 'deep_dive',
  reportId: 'r1',
  blockIds: ['link:https://example.com/me'],
  quoteTitle: 'Personal Website',
  quoteText: 'https://example.com/me',
);

void main() {
  setUp(() {
    AymaSession.instance.store.seed(const []);
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    ValueChanged<int>? onSelected,
  }) async {
    // Phone-size surface: on the default 800x600 test box the docked sheet
    // is too short for the transcript to build any rows at all.
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AymaNavBarScope(
        navBarBuilder: (_) => AymaTabBar(
          index: -1,
          voice: null,
          onSelected: onSelected ?? (_) {},
        ),
        child: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAskAymaOverlay(
                context,
                api: _FakeApi(),
                ctx: _ctx,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'partial scoped sheet hides history; the exchange still lands in main '
      'chat and expanding reveals it', (tester) async {
    AymaSession.instance.store.seed([
      TranscriptTurn(
        role: TurnRole.ayma,
        text: 'Main history hello',
        source: TurnSource.text,
      ),
    ]);
    await pumpHost(tester);

    // Partial: no history turns listed, not even the divider…
    expect(find.text('Main history hello'), findsNothing);
    expect(
      find.byKey(const ValueKey('chat-conversation-divider')),
      findsNothing,
    );
    // …just the scoped context card, the quick chips and the composer.
    expect(find.text('"https://example.com/me"'), findsOneWidget);
    expect(find.text('Make private'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);

    await tester.enterText(find.byType(TextField).last, 'Delete');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // …and the correction exchange is IN the main conversation now.
    final texts = [
      for (final t in AymaSession.instance.store.turns) t.text,
    ];
    expect(texts, contains('Main history hello'));
    expect(texts, contains('Delete'));
    expect(texts, contains('Done — removed.'));

    // Expanding reveals the whole conversation, new turns included.
    await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
    await tester.pumpAndSettle();
    expect(aymaSheet.isExpanded, isTrue);
    expect(
      find.byKey(const ValueKey('chat-conversation-divider')),
      findsOneWidget,
    );
    expect(find.text('Main history hello'), findsOneWidget);
    expect(find.text('Done — removed.'), findsOneWidget);
    // The sent turn, plus the 'Delete' quick chip now pinned above the
    // composer (history listed again, so the body placement stands down).
    expect(find.text('Delete'), findsWidgets);
  });

  testWidgets('scoped sheet keeps the nav bar and expands to full chat',
      (tester) async {
    await pumpHost(tester);

    expect(find.byKey(_navBarCopy), findsOneWidget);
    expect(find.byKey(const Key('chatExpandFullscreenButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
    await tester.pumpAndSettle();
    expect(aymaSheet.isExpanded, isTrue);
    expect(find.byKey(const Key('chatCollapseFullscreenButton')), findsOneWidget);
  });

  testWidgets('a second orb tap expands the scoped sheet, never voices',
      (tester) async {
    var voiced = 0;
    await pumpHost(
      tester,
      onSelected: (i) {
        if (i != 0) return;
        if (isAymaSheetOpen) {
          orbTapOnOpenSheet(onVoice: () => voiced++);
        }
      },
    );

    Finder popupOrb() => find.descendant(
          of: find.byKey(_navBarCopy),
          matching: find.byTooltip('Ayma'),
        );

    // Docked scoped sheet -> grow to full chat.
    await tester.tap(popupOrb());
    await tester.pumpAndSettle();
    expect(aymaSheet.isExpanded, isTrue);
    expect(voiced, 0);

    // Already full — still no voice from a scoped turn.
    await tester.tap(popupOrb());
    await tester.pumpAndSettle();
    expect(aymaSheet.isExpanded, isTrue);
    expect(voiced, 0);
  });
}
