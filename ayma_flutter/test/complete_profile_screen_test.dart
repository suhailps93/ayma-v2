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

Map<String, dynamic> _section(
  String pageType,
  String label, {
  required bool unlocked,
  int pct = 0,
  int answered = 0,
  int total = 0,
  int coreTotal = 0,
  int coreAnswered = 0,
  int priority = 5,
}) =>
    {
      'page_type': pageType,
      'label': label,
      'pct': pct,
      'answered': answered,
      'total': total,
      'unlocked': unlocked,
      'core_total': coreTotal,
      'core_answered': coreAnswered,
      'priority': priority,
    };

/// `intentSet:false` mirrors the backend: only the global-core sections come
/// back, and the routing section is folded into its own CTA.
Map<String, dynamic> _completeness({
  int score = 62,
  bool intentSet = false,
  String intent = 'long_term',
  bool identityCoreDone = false,
}) =>
    {
      'score': score,
      'visible_score': 80,
      'intent': intent,
      'intent_set': intentSet,
      'sections': [
        _section('identity', 'Identity & basics',
            unlocked: true,
            pct: identityCoreDone ? 80 : 40,
            answered: identityCoreDone ? 2 : 1,
            total: 3,
            coreTotal: 2,
            coreAnswered: identityCoreDone ? 2 : 1),
        _section('personality', 'Personality & temperament',
            unlocked: false, total: 1, coreTotal: 1),
        if (intentSet)
          _section('goals', 'Goals & timelines',
              unlocked: false, total: 1, coreTotal: 1, priority: 5),
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
          'tier': 'core',
          'unlocked': true,
        },
      ],
      'updated_at': '2026-09-10T12:34:56Z',
    };

Map<String, dynamic> _node(
  String id,
  String pageType,
  String label, {
  String tier = 'core',
  String status = 'missing',
  bool unlocked = true,
}) =>
    {
      'id': id,
      'page_type': pageType,
      'label': label,
      'kind': 'text',
      'tier': tier,
      'status': status,
      'unlocked': unlocked,
    };

Map<String, dynamic> _questionnaire({
  bool intentSet = false,
  bool identityCoreDone = false,
}) =>
    {
      'intent': 'long_term',
      'intent_set': intentSet,
      'score': 62,
      'visible_score': 80,
      'nodes': [
        _node('legal_name', 'identity', 'Legal name', status: 'covered'),
        _node('hometown', 'identity', 'Hometown',
            status: identityCoreDone ? 'covered' : 'missing'),
        _node('backstory', 'identity', 'Backstory',
            tier: 'deep', unlocked: identityCoreDone),
        _node('attachment', 'personality', 'Attachment style', unlocked: false),
        _node('relationship_intent', 'relationships', 'Relationship intent',
            unlocked: true),
        if (intentSet) _node('kids', 'goals', 'Kids & timeline', unlocked: false),
      ],
    };

void main() {
  tearDown(() => ChatInbox.instance.take());

  void sized(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('renders the ring and the score', (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(score: 62),
      questionnaire: _questionnaire(),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(CompletenessRing), findsOneWidget);
    expect(find.text('Your profile is 62% complete'), findsOneWidget);
  });

  testWidgets('!intentSet: shows the intent CTA and hides branch sections',
      (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: false),
      questionnaire: _questionnaire(intentSet: false),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Ayma is still figuring out what you want'), findsOneWidget);
    expect(
        find.textContaining('More sections open up once Ayma'), findsOneWidget);
    // no branch section, locked or otherwise
    expect(find.text('Goals & timelines'), findsNothing);
    // the "Tuned for:" quiet line is only for a set intent
    expect(find.text('Tuned for: '), findsNothing);
  });

  testWidgets('the intent CTA pushes a discuss_topic kickoff and navigates',
      (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: false),
      questionnaire: _questionnaire(intentSet: false),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ayma is still figuring out what you want'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'discuss_topic');
    expect(k.nodeId, 'relationship_intent');
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('"Tuned for: X" renders when the intent is set', (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: true, intent: 'casual'),
      questionnaire: _questionnaire(intentSet: true),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Tuned for: '), findsOneWidget);
    expect(find.text('Casual'), findsOneWidget);
    expect(
        find.text('Ayma is still figuring out what you want'), findsNothing);
  });

  testWidgets('a locked section is dimmed, lock-marked and non-expandable',
      (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: true),
      questionnaire: _questionnaire(intentSet: true),
    )));
    await tester.pumpAndSettle();

    expect(find.text('UNLOCKS AS YOU GO'), findsOneWidget);
    expect(find.text('Personality & temperament'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);

    // tapping a locked section reveals nothing
    await tester.tap(find.text('Personality & temperament'));
    await tester.pumpAndSettle();
    expect(find.text('Attachment style'), findsNothing);
  });

  testWidgets('an unlocked section hides its deep nodes until core is covered',
      (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: true, identityCoreDone: false),
      questionnaire: _questionnaire(intentSet: true, identityCoreDone: false),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Identity & basics'));
    await tester.pumpAndSettle();

    expect(find.text('Legal name'), findsOneWidget); // core
    expect(find.text('Hometown'), findsOneWidget); // core
    expect(find.text('Backstory'), findsNothing); // deep, still gated
    expect(find.textContaining('More detail unlocks after the basics'),
        findsOneWidget);
  });

  testWidgets('an unlocked section shows deep nodes once core is covered',
      (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: true, identityCoreDone: true),
      questionnaire: _questionnaire(intentSet: true, identityCoreDone: true),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Identity & basics'));
    await tester.pumpAndSettle();

    expect(find.text('Backstory'), findsOneWidget);
    expect(find.textContaining('More detail unlocks after the basics'),
        findsNothing);
  });

  testWidgets('a section "Talk to Ayma about this" pushes the first open node',
      (tester) async {
    sized(tester);
    await tester.pumpWidget(_host(_api(
      completeness: _completeness(intentSet: true),
      questionnaire: _questionnaire(intentSet: true),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Identity & basics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Talk to Ayma about this'));
    await tester.pumpAndSettle();

    final k = ChatInbox.instance.pending.value;
    expect(k, isNotNull);
    expect(k!.kind, 'discuss_topic');
    // 'legal_name' is covered; 'hometown' is the first open (and unlocked) node
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
