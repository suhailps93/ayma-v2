// Founder build 2493: tapping a node opened the Ask Ayma sheet whose context
// card printed the SAME statement twice — once as the small-caps header and once
// as the italic quote — because an emergent narrative node stored the identical
// string in both its prompt (label) field and its answer (text) field. The card
// must collapse to showing the statement ONCE when the header merely restates
// the quote.
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _statement = 'I love long hikes in the hills.';

void main() {
  testWidgets(
      'context card shows a prompt==answer statement ONCE, not duplicated',
      (tester) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = ApiClient(auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: api,
        // The duplicated node: the same statement in BOTH fields.
        askAymaContext: const AskAymaContext(
          origin: AskAymaOrigin.graphNode,
          quoteTitle: _statement,
          quoteText: _statement,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The italic quote renders once.
    expect(find.text('"$_statement"'), findsOneWidget);
    // The duplicate small-caps header (the title, upper-cased) is collapsed
    // away — the statement is not printed a second time.
    expect(find.text(_statement.toUpperCase()), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('context card keeps a distinct header alongside the quote',
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
          quoteText: _statement,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // A genuinely different header is preserved (only exact restatements drop).
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.text('"$_statement"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
