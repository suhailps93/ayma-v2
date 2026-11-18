// Gist-first rendering (less-text-heavy program, Part 1): a node renders its
// short GIST line by default on every surface; the full prose appears only on
// tap-in (the node chat window). Verified across a Story fixture and a report
// fixture.
import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _longProse =
    'I spent my twenties backpacking across South America. It changed how I '
    'see the world and what I want from a partner, which is someone curious.';
const _gist = 'I spent my twenties backpacking across South America';

StoryNode _proseNode({
  required String id,
  required String vis,
  String section = 'identity',
}) =>
    StoryNode(
      id: id,
      section: section,
      label: '',
      text: _longProse,
      gist: _gist,
      answerType: 'narrative',
      level: 1,
      visibility: vis,
      subtreeVisibility: vis,
      standard: false,
      editable: true,
    );

ApiClient _api() => ApiClient(auth: MockFirebaseAuth(signedIn: true));

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  // The partial node chat is the one shared ChatScreen against the session
  // store; seed it so opening the overlay never reaches for server history.
  setUp(() => AymaSession.instance.store.seed(const []));

  testWidgets(
      'STORY: a node shows its gist line by default, not the full prose; '
      'tapping it opens the chat with the full prose', (tester) async {
    await tester.pumpWidget(_host(NodeVisualiser(
      node: _proseNode(id: 'n1', vis: NodeVis.public),
      surface: NodeVisualiserSurface.story,
      api: _api(),
    )));
    await tester.pumpAndSettle();

    // Default (collapsed) render is the short gist — the wall of prose is hidden.
    expect(find.text(_gist), findsOneWidget);
    expect(find.text(_longProse), findsNothing);

    // Tap-in keeps the existing target: the partial node chat, carrying the
    // full prose as its pinned context card.
    await tester.tap(find.byKey(const Key('node_row_n1')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    // The full prose is handed to the chat as its context (the collapsed gist
    // row's tap reveals the whole thing, not just the headline).
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.askAymaContext?.quoteText, _longProse);
  });

  testWidgets(
      'REPORT: a report-surface node renders gist-first and reveals the full '
      'prose on tap', (tester) async {
    final section = GraphTreeSection(
      pageType: 'face',
      title: 'Face',
      order: 0,
      nodes: [_proseNode(id: 'r1', vis: NodeVis.public, section: 'face')],
    );
    await tester.pumpWidget(_host(NodeVisualiserSection(
      section: section,
      surface: NodeVisualiserSurface.report,
      api: _api(),
      isOwner: false,
    )));
    await tester.pumpAndSettle();

    expect(find.text(_gist), findsOneWidget);
    expect(find.text(_longProse), findsNothing);

    await tester.tap(find.byKey(const Key('node_row_r1')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.askAymaContext?.quoteText, _longProse);
  });

  testWidgets(
      'P0 CONTROLS: tapping a collapsed gist row opens the partial chat with '
      'the full owner controls (Make public/private, Edit, Add a line, Delete)',
      (tester) async {
    await tester.pumpWidget(_host(NodeVisualiser(
      node: _proseNode(id: 'n1', vis: NodeVis.private),
      surface: NodeVisualiserSurface.story,
      api: _api(),
    )));
    await tester.pumpAndSettle();
    // The row is a gist line, yet it is as controllable as the old bullet.
    await tester.tap(find.byKey(const Key('node_row_n1')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byKey(const Key('bubble_visibility')), findsOneWidget);
    expect(find.text('Make public'), findsOneWidget); // private → offers public
    expect(find.byKey(const Key('bubble_add_child')), findsOneWidget);
    expect(find.byKey(const Key('bubble_delete')), findsOneWidget);
  });

  testWidgets(
      'P0 PRIVACY: a private node never surfaces its gist on the public '
      'profile', (tester) async {
    StoryNode node() => _proseNode(id: 'secret', vis: NodeVis.private);
    // Story (owner surface): the gist renders.
    await tester.pumpWidget(_host(NodeVisualiser(
      node: node(), surface: NodeVisualiserSurface.story, api: _api())));
    await tester.pumpAndSettle();
    expect(find.text(_gist), findsOneWidget);
    // Public profile: the whole node (gist included) is filtered out.
    await tester.pumpWidget(_host(NodeVisualiser(
      node: node(),
      surface: NodeVisualiserSurface.publicProfile,
      api: _api())));
    await tester.pumpAndSettle();
    expect(find.text(_gist), findsNothing);
    expect(find.byKey(const Key('node_row_secret')), findsNothing);
  });

  testWidgets('a node WITHOUT a gist falls back to its full text', (tester) async {
    // No gist supplied (existing nodes before Part 3's writer) → the row shows
    // the node text as before, so nothing regresses.
    final node = StoryNode(
      id: 'n2',
      section: 'identity',
      label: '',
      text: 'Loves hiking',
      answerType: 'narrative',
      level: 1,
      visibility: NodeVis.public,
      subtreeVisibility: NodeVis.public,
      standard: false,
      editable: true,
    );
    await tester.pumpWidget(_host(NodeVisualiser(
      node: node,
      surface: NodeVisualiserSurface.story,
      api: _api(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Loves hiking'), findsOneWidget);
  });
}
