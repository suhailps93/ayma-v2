// Nov 16 2026 founder direction: the person graph must show EVERYTHING in the
// store (reports, photos, skills, assessment, …), neural-network style, each
// tappable node opening its report or photo. These cover the routing logic and
// that the renderer handles every new node kind without breaking.
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PersonGraph _graph() => PersonGraph.fromMap({
      'center': {'id': 'me', 'label': 'You'},
      'sections': const [],
      'nodes': [
        {'id': 'me', 'kind': 'person', 'label': 'You'},
        {'id': 'sec:appearance', 'kind': 'section', 'label': 'Appearance'},
        {
          'id': 'emergent.appearance.report',
          'kind': 'report',
          'label': 'Appearance report',
          'text': 'Face 7.0',
          'visibility': 'private',
          'open': {'type': 'appearance_report', 'id': 'current'},
        },
        {
          'id': 'emergent.webfind.report.RID123',
          'kind': 'report',
          'label': 'Web findings',
          'visibility': 'private',
          'open': {'type': 'webfind_report', 'id': 'RID123'},
        },
        {
          'id': 'emergent.image.p1',
          'kind': 'image',
          'label': 'Photo',
          'text': 'A man smiling',
          'image_url': 'https://cdn/p1.jpg',
          'visibility': 'public',
          'open': {'type': 'image', 'url': 'https://cdn/p1.jpg', 'read': 'A man smiling'},
        },
        {
          'id': 'emergent.skill.physical',
          'kind': 'skill',
          'label': 'Physical profile',
          'visibility': 'private',
        },
        {'id': 'b:1', 'kind': 'bullet', 'text': 'I grew up in Lahore.', 'visibility': 'public'},
      ],
      'edges': [
        {'from': 'me', 'to': 'sec:appearance'},
        {'from': 'sec:appearance', 'to': 'emergent.appearance.report'},
        {'from': 'sec:appearance', 'to': 'emergent.webfind.report.RID123'},
        {'from': 'sec:appearance', 'to': 'emergent.image.p1'},
        {'from': 'sec:appearance', 'to': 'emergent.skill.physical'},
        {'from': 'sec:appearance', 'to': 'b:1'},
      ],
    });

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<PersonGraph> profileGraph({String? uid}) async => _graph();
}

GraphNode _node(Map<String, dynamic> open) =>
    GraphNode.fromMap({'id': 'x', 'kind': 'report', 'open': open});

void main() {
  group('graphOpenRoute', () {
    test('an appearance report node pushes /appearance/<id>', () {
      expect(graphOpenRoute(_node({'type': 'appearance_report', 'id': 'current'})),
          '/appearance/current');
      // Missing id falls back to the current report.
      expect(graphOpenRoute(_node({'type': 'appearance_report'})),
          '/appearance/current');
    });

    test('a web-findings node pushes /deep-dive/<id>', () {
      expect(graphOpenRoute(_node({'type': 'webfind_report', 'id': 'RID123'})),
          '/deep-dive/RID123');
    });

    test('an image node has no push route (it opens the photo viewer)', () {
      final img = GraphNode.fromMap({
        'id': 'i',
        'kind': 'image',
        'image_url': 'https://cdn/p.jpg',
        'open': {'type': 'image', 'url': 'https://cdn/p.jpg', 'read': 'read'},
      });
      expect(graphOpenRoute(img), isNull);
      expect(img.openType, 'image');
      expect(img.imageUrl, 'https://cdn/p.jpg');
      expect(img.isOpenable, isTrue);
    });

    test('a plain fact node is not openable', () {
      final b = GraphNode.fromMap({'id': 'b', 'kind': 'bullet', 'text': 'x'});
      expect(graphOpenRoute(b), isNull);
      expect(b.isOpenable, isFalse);
    });
  });

  testWidgets('renders every node kind and opens the legend without overflow',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PersonGraphScreen(api: _FakeApi()),
    ));
    // The graph loads (don't pumpAndSettle — the neural pulse never settles).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The neural canvas painted (CustomPaint present), with no layout overflow
    // (an overflow would have thrown during pump).
    expect(find.byType(CustomPaint), findsWidgets);

    // The legend lists the new node kinds.
    await tester.tap(find.byTooltip('What the colours mean'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text("Ayma's read"), findsOneWidget);
  });
}
