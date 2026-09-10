import 'dart:convert';

import 'package:ayma_flutter/screens/complete_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/widgets/completeness_ring.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

ApiClient _api({
  required Map<String, dynamic> completeness,
  required Map<String, dynamic> questionnaire,
}) {
  final mockHttp = MockClient((req) async {
    if (req.url.path == '/completeness') {
      return http.Response(jsonEncode(completeness), 200, headers: _jsonUtf8);
    }
    if (req.url.path == '/questionnaire') {
      return http.Response(jsonEncode(questionnaire), 200, headers: _jsonUtf8);
    }
    return http.Response('{}', 200, headers: _jsonUtf8);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(ApiClient api) {
  final router = GoRouter(
    initialLocation: CompleteProfileScreen.path,
    routes: [
      GoRoute(
        path: CompleteProfileScreen.path,
        builder: (_, __) => CompleteProfileScreen(apiClient: api),
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

Map<String, dynamic> _completeness({
  int score = 62,
  bool intentSet = false,
}) =>
    {
      'score': score,
      'intent': 'long_term',
      'intent_set': intentSet,
      'sections': [
        {
          'page_type': 'identity',
          'label': 'Identity & basics',
          'pct': 40,
          'answered': 2,
          'total': 7,
        },
        {
          'page_type': 'relationships',
          'label': 'Relationships',
          'pct': 50,
          'answered': 1,
          'total': 2,
        },
      ],
      'next': [
        {
          'id': 'relationship_intent',
          'label': 'Relationship intent',
          'page_type': 'relationships',
          'kind': 'enum',
          'options': ['Casual', 'Long-term', 'Marriage', 'Not sure yet'],
          'ayma_prompt': "what kind of relationship they're actually here for",
          'weight': 5,
        },
      ],
      'updated_at': '2026-09-10T12:34:56Z',
    };

Map<String, dynamic> _questionnaire() => {
      'intent': 'long_term',
      'intent_set': false,
      'score': 62,
      'nodes': [
        {
          'id': 'legal_name',
          'page_type': 'identity',
          'label': 'Legal name',
          'kind': 'text',
          'status': 'covered',
        },
        {
          'id': 'hometown',
          'page_type': 'identity',
          'label': 'Hometown',
          'kind': 'text',
          'status': 'partial',
        },
        {
          'id': 'occupation',
          'page_type': 'identity',
          'label': 'Occupation',
          'kind': 'text',
          'status': 'missing',
        },
        {
          'id': 'relationship_intent',
          'page_type': 'relationships',
          'label': 'Relationship intent',
          'kind': 'enum',
          'status': 'missing',
          'ayma_prompt': 'what they want',
        },
      ],
    };

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets('renders the ring and the score', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(
      completeness: _completeness(score: 62),
      questionnaire: _questionnaire(),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(CompletenessRing), findsOneWidget);
    expect(find.text('Your profile is 62% complete'), findsOneWidget);
    expect(find.textContaining('more accurate matches'), findsWidgets);
  });

  testWidgets('the !intentSet callout shows and its button pushes a '
      'discuss_topic kickoff and navigates to the shell', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: false),
      questionnaire: _questionnaire(),
    )));
    await tester.pumpAndSettle();

    expect(find.text("First: tell Ayma what you're looking for"), findsOneWidget);

    await tester.tap(find.text('Talk to Ayma about this'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'discuss_topic');
    expect(k.nodeId, 'relationship_intent');
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('a section row expands to reveal node status dots', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(
      completeness: _completeness(),
      questionnaire: _questionnaire(),
    )));
    await tester.pumpAndSettle();

    // Collapsed: node labels are not shown yet.
    expect(find.text('Occupation'), findsNothing);

    await tester.tap(find.text('Identity & basics'));
    await tester.pumpAndSettle();

    expect(find.text('Legal name'), findsOneWidget);
    expect(find.text('Hometown'), findsOneWidget);
    expect(find.text('Occupation'), findsOneWidget);
  });

  testWidgets('a section "Talk to Ayma about this" pushes a kickoff with the '
      'first uncovered node id and navigates', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: true),
      questionnaire: _questionnaire(),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Identity & basics'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Talk to Ayma about this'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'discuss_topic');
    // 'legal_name' is covered, 'hometown' is the first non-covered node.
    expect(k.nodeId, 'hometown');
    expect(k.label, 'Identity & basics');
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('shows a retry message when the fetch fails', (tester) async {
    final mockHttp = MockClient((_) async => http.Response('boom', 500));
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load your profile progress"),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
