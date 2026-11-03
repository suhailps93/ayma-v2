// D12: the Ask Ayma sheet's highlighted-item card shows the FULL text — it
// sizes to the item, never truncates, and at a normal phone size the whole
// card is on screen with no scrolling needed. (Only a pathological quote in
// a tiny window ever scrolls the header region — the overflow guard the
// layout matrix proves — and even then the card itself never truncates.)
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:ayma_flutter/widgets/overflow_guards.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _longQuote =
    'Led the payments migration across three regions. Cut p99 latency in half. '
    'Mentored four engineers into senior roles. Shipped the offline mode users '
    'had asked about for two years. Presented the results at the company '
    'all-hands to a standing ovation from the platform team.';

void main() {
  testWidgets('context card shows the full item text with no truncation',
      (tester) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = ApiClient(auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        askAymaContext: const AskAymaContext(
          origin: AskAymaOrigin.report,
          quoteTitle: 'Projects',
          quoteText: _longQuote,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Never truncates: the full text renders with no line cap, no ellipsis.
    final quote = find.text('"$_longQuote"');
    expect(quote, findsOneWidget);
    final text = tester.widget<Text>(quote);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    // Sizes to the item with no scrolling needed: the whole quote sits
    // inside the header region's viewport (a too-small cap would clip it
    // and force a scroll to see the end).
    final cap = find.ancestor(of: quote, matching: find.byType(CappedScroll));
    expect(cap, findsOneWidget);
    expect(
      tester.getBottomRight(quote).dy,
      lessThanOrEqualTo(tester.getBottomRight(cap).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
