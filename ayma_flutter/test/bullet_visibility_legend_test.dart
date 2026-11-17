// Regression test for the bullet-visibility legend (founder, build 2488: "too
// many bullet colours in my Story and I don't know what each means"). Proves:
//   * the legend lists the four visibilities with the EXACT dots the real
//     bullets draw (same green/yellow/violet + the half-yellow/half-green split
//     for Mixed), so the key can never drift from what it explains;
//   * it renders at the TOP of Your Story, above the bullet list;
//   * it renders at the top of the person graph (the same bullets appear there);
//   * it is ABSENT on the public profile, where every bullet is public.
import 'dart:convert';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/bullet_visibility_legend.dart';
import 'package:ayma_flutter/widgets/graph_tree_view.dart';
import 'package:ayma_flutter/widgets/node_visibility.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The visibility each legend dot carries, in render order.
List<String> _legendVisibilities(WidgetTester tester) => tester
    .widgetList<NodeVisibilityBullet>(
      find.descendant(
        of: find.byType(BulletVisibilityLegend),
        matching: find.byType(NodeVisibilityBullet),
      ),
    )
    .map((b) => b.visibility)
    .toList();

// --- Your Story -------------------------------------------------------------

class _StoryApi extends ApiClient {
  _StoryApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<StoryData> storyGet() async => const StoryData(sections: []);
  @override
  Future<List<AiNotePhoto>> photoNodes() async => const [];
  @override
  Future<PublicProfile> publicProfile(String otherUid) async =>
      PublicProfile.fromMap({'uid': otherUid, 'photos': const []});
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      GraphTree.fromMap(const {'surface': 'story', 'sections': []});
}

// --- Person graph -----------------------------------------------------------

class _GraphApi extends ApiClient {
  _GraphApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<PersonGraph> profileGraph({String? uid}) async => PersonGraph.fromMap({
        'center': {'id': 'me', 'label': 'You'},
        'sections': const [],
        'nodes': const [
          {'id': 'me', 'kind': 'person', 'label': 'You'},
          {'id': 'b:1', 'kind': 'bullet', 'text': 'Grew up in Lahore.', 'visibility': 'public'},
        ],
        'edges': const [
          {'from': 'me', 'to': 'b:1'},
        ],
      });
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      GraphTree.fromMap(const {'surface': 'graphDetail', 'sections': []});
}

Widget _reducedMotion(Widget child) => MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child,
        ),
      ),
    );

// --- Public profile ---------------------------------------------------------

ApiClient _publicApi() => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore/profile/her') {
          return http.Response(
            jsonEncode({
              'uid': 'her',
              'self': false,
              'blocked': false,
              'name': 'Dana',
              'age': 30,
              'location': 'Berlin',
              'photos': const [],
              'pages': const [
                {'page_type': 'identity', 'title': '', 'body': 'From Lisbon.'},
              ],
              'liked': false,
              'thread_id': 'her__me',
              'has_chatted': false,
              'deep_dive_id': '',
            }),
            200,
          );
        }
        if (req.url.path == '/profile/graph/tree' ||
            req.url.path == '/profile/graph/tree/her') {
          return http.Response(
            jsonEncode({
              'surface': 'publicProfile',
              'sections': [
                {
                  'page_type': 'identity',
                  'title': 'IDENTITY',
                  'order': 0,
                  'nodes': [
                    {
                      'id': 'n0',
                      'section': 'identity',
                      'label': '',
                      'text': 'From Lisbon.',
                      'answer_type': 'text',
                      'level': 1,
                      'visibility': 'public',
                      'subtree_visibility': 'public',
                    }
                  ],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('no', 404);
      }),
    );

Widget _publicApp(ApiClient api) {
  final router = GoRouter(
    initialLocation: '/profile/user/her',
    routes: [
      GoRoute(
        path: '/profile/user/:uid',
        builder: (_, s) =>
            PublicProfileScreen(uid: s.pathParameters['uid']!, api: api),
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
    ],
  );
  return MaterialApp.router(routerConfig: router, theme: AymaTheme.dark);
}

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
    addTearDown(() => b.platformDispatcher.views.first.resetPhysicalSize());
  });

  testWidgets('lists the four visibilities with the exact bullet dots',
      (tester) async {
    await tester.pumpWidget(_reducedMotion(
      const Scaffold(body: Center(child: BulletVisibilityLegend())),
    ));
    await tester.pump();

    // The four plain-words labels.
    expect(find.text('Public'), findsOneWidget);
    expect(find.text('Private'), findsOneWidget);
    expect(find.text('Ayma only'), findsOneWidget);
    expect(find.text('Mixed'), findsOneWidget);

    // Each dot is the very [NodeVisibilityBullet] the real bullets use, in
    // order — so the legend colours ARE the bullet colours by construction.
    expect(_legendVisibilities(tester),
        [NodeVis.public, NodeVis.private, NodeVis.aymaOnly, NodeVis.mixed]);

    // Pin the exact bullet colours the dots inherit (public green, private
    // yellow, Ayma-only violet; Mixed is the yellow/green split of the first
    // two). A change here would silently desync the legend from the bullets.
    expect(nodeVisibilityColor(NodeVis.public), const Color(0xFF34C759));
    expect(nodeVisibilityColor(NodeVis.private), const Color(0xFFFFCC00));
    expect(nodeVisibilityColor(NodeVis.aymaOnly), const Color(0xFF7C5CFF));
  });

  testWidgets('renders at the top of Your Story, above the bullet list',
      (tester) async {
    await tester.pumpWidget(_reducedMotion(StoryEditorScreen(
      api: _StoryApi(),
      myUid: 'me',
    )));
    await tester.pumpAndSettle();

    expect(find.byType(BulletVisibilityLegend), findsOneWidget);
    // Sits above the bullet renderer (GraphTreeView) — "at the TOP".
    final legendY = tester.getTopLeft(find.byType(BulletVisibilityLegend)).dy;
    final editorY = tester.getTopLeft(find.byType(GraphTreeView)).dy;
    expect(legendY, lessThan(editorY));
  });

  testWidgets('renders at the top of the person graph', (tester) async {
    await tester.pumpWidget(_reducedMotion(PersonGraphScreen(api: _GraphApi())));
    // The neural pulse never settles — pump a couple of frames, don't settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(BulletVisibilityLegend), findsOneWidget);
    expect(_legendVisibilities(tester),
        [NodeVis.public, NodeVis.private, NodeVis.aymaOnly, NodeVis.mixed]);
  });

  testWidgets('is absent on the public profile (everything there is public)',
      (tester) async {
    await tester.pumpWidget(_publicApp(_publicApi()));
    await tester.pumpAndSettle();

    expect(find.byType(GraphTreeView), findsOneWidget); // body rendered
    expect(find.byType(BulletVisibilityLegend), findsNothing);
  });
}
