// Offline-first (resilience chunk C): the REST-backed screens paint their
// last-known content from the on-device cache the moment they open, then
// refresh behind it. Covers the cache models' map round-trips, the Explore
// feed painting its cached page 1 while the network fetch is still in
// flight (and persisting the fresh page over it), and the Plan page
// painting its cached snapshot while /usage is still in flight.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/plan_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/services/subscription_status.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show PeriodUnit;
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'u1';
const _exploreKey = 'report_cache:$_uid:last_known:explore_feed';
const _planKey = 'report_cache:$_uid:last_known:plan';
const _chatKey = 'report_cache:$_uid:last_known:chat_history';
const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _cardJson(String uid, String name) => {
      'uid': uid,
      'name': name,
      'age': 29,
      'location': 'San Jose',
      'photo_path': null,
      'photo_url': '',
      'photo_url_thumb': '',
      'score': 0.5,
      'liked': false,
      'mutual': false,
      'self': false,
      'paused': false,
    };

class _FakeRc extends RevenueCatService {
  @override
  bool get enabled => false;

  @override
  Future<List<PlanOption>> plans() async => const [
        PlanOption(
          name: 'Pro',
          productId: 'ayma_pro_monthly',
          price: 'FRESH_PRICE',
          blurb: 'b',
          credits: 100,
        ),
      ];

  @override
  Future<ActiveSubscription?> activeSubscription() async => null;

  @override
  Future<TrialOffer?> proTrialOffer() async => null;
}

Map<String, dynamic> _usageJson() => {
      'total': 10,
      'features': <String, int>{},
      'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
      'tokens_per_credit': 1000,
      'plan': 'pro',
      'spend_groups': [],
      'period_usage': {
        'period': '7d',
        'since': null,
        'features': [],
        'total_credits': 0,
      },
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ChatInbox.instance.take());

  group('cache model round-trips', () {
    test('ExploreCard toMap/fromMap is lossless', () {
      const card = ExploreCard(
        uid: 'x1',
        name: 'Xena',
        age: 31,
        location: 'Denver',
        photoPath: 'p/x.jpg',
        photoUrl: 'https://img/x',
        photoUrlThumb: 'https://img/xt',
        score: 0.75,
        liked: true,
        mutual: true,
        paused: true,
      );
      final back = ExploreCard.fromMap(card.toMap());
      expect(back.uid, card.uid);
      expect(back.name, card.name);
      expect(back.age, card.age);
      expect(back.location, card.location);
      expect(back.photoPath, card.photoPath);
      expect(back.photoUrl, card.photoUrl);
      expect(back.photoUrlThumb, card.photoUrlThumb);
      expect(back.score, card.score);
      expect(back.liked, isTrue);
      expect(back.mutual, isTrue);
      expect(back.isSelf, isFalse);
      expect(back.paused, isTrue);
    });

    test('UsageSummary toMap/fromMap is lossless', () {
      final usage = UsageSummary(
        total: 99,
        features: const {'chat': 10, 'voice': 5},
        creditGrant: 100,
        creditsAdded: 20,
        creditsUsed: 30,
        creditsRemaining: 90,
        tokensPerCredit: 500,
        costUsd: 1.5,
        realMoneyUsd: 2.5,
        realMoneyAllTimeUsd: 3.5,
        realMoneyResetAt: DateTime.utc(2026, 11, 1),
        spendGroups: [
          SpendGroup(
            id: 'g1',
            kind: 'chat',
            sessionId: 's1',
            day: '2026-11-01',
            lastTs: DateTime.utc(2026, 11, 1, 12),
            events: 3,
            costUsd: 0.25,
            features: const {'chat': 0.25},
          ),
        ],
        periodUsage: PeriodUsage(
          period: '7d',
          since: DateTime.utc(2026, 10, 25),
          features: const [PeriodFeature(label: 'Chat', credits: 7)],
          totalCredits: 7,
        ),
        isDev: true,
        plan: 'pro',
        periodEnd: DateTime.utc(2026, 12, 1),
        isTrial: true,
      );
      final back = UsageSummary.fromMap(usage.toMap());
      expect(back.total, 99);
      expect(back.features, {'chat': 10, 'voice': 5});
      expect(back.creditGrant, 100);
      expect(back.creditsAdded, 20);
      expect(back.creditsUsed, 30);
      expect(back.creditsRemaining, 90);
      expect(back.tokensPerCredit, 500);
      expect(back.costUsd, 1.5);
      expect(back.realMoneyUsd, 2.5);
      expect(back.realMoneyAllTimeUsd, 3.5);
      expect(back.realMoneyResetAt, DateTime.utc(2026, 11, 1));
      expect(back.spendGroups.single.id, 'g1');
      expect(back.spendGroups.single.features, {'chat': 0.25});
      expect(back.periodUsage?.totalCredits, 7);
      expect(back.periodUsage?.features.single.label, 'Chat');
      expect(back.isDev, isTrue);
      expect(back.plan, 'pro');
      expect(back.periodEnd, DateTime.utc(2026, 12, 1));
      expect(back.isTrial, isTrue);
    });

    test('ChatMessage toMap/fromMap is lossless', () {
      final msg = ChatMessage(
        role: 'ayma',
        text: 'hello there',
        imagePath: 'uploads/u1/a.jpg',
        imageUrl: 'https://img/a',
        tools: const ['Searched the web'],
        subjectImage: 'https://img/subj',
        createdAt: DateTime.utc(2026, 11, 2, 9, 30),
        clientMsgId: 'cmid-1',
      );
      final back = ChatMessage.fromMap(msg.toMap());
      expect(back.role, msg.role);
      expect(back.text, msg.text);
      expect(back.imagePath, msg.imagePath);
      expect(back.imageUrl, msg.imageUrl);
      expect(back.tools, msg.tools);
      expect(back.subjectImage, msg.subjectImage);
      expect(back.createdAt, msg.createdAt);
      expect(back.clientMsgId, msg.clientMsgId);
    });

    test('SubscriptionStatus + PlanOption + TrialOffer round-trip', () {
      final status = SubscriptionStatus(
        planName: 'Pro',
        productId: 'ayma_pro_monthly',
        expiresAt: DateTime.utc(2026, 12, 15),
        willRenew: false,
        managementUrl: 'https://store/manage',
        isTrial: true,
        fromStore: true,
      );
      final back = SubscriptionStatus.fromMap(status.toMap());
      expect(back.planName, 'Pro');
      expect(back.productId, 'ayma_pro_monthly');
      expect(back.expiresAt, DateTime.utc(2026, 12, 15));
      expect(back.willRenew, isFalse);
      expect(back.managementUrl, 'https://store/manage');
      expect(back.isTrial, isTrue);
      expect(back.fromStore, isTrue);

      const plan = PlanOption(
        name: 'Pro',
        productId: 'ayma_pro_monthly',
        price: r'$20',
        blurb: 'b',
        credits: 1400,
      );
      final planBack = PlanOption.fromMap(plan.toMap());
      expect(planBack.productId, plan.productId);
      expect(planBack.price, plan.price);
      expect(planBack.credits, plan.credits);
      expect(planBack.package, isNull); // display-only when restored

      final trial = TrialOffer(plan: plan, unit: PeriodUnit.day, value: 30);
      final trialBack = TrialOffer.fromMap(trial.toMap(), [planBack]);
      expect(trialBack?.value, 30);
      expect(trialBack?.unit, PeriodUnit.day);
      expect(trialBack?.plan.productId, plan.productId);
    });
  });

  testWidgets('Explore paints the cached page 1 while the fetch is in flight, '
      'then the fresh page swaps in and is persisted', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(AppContext.instance.clear);

    SharedPreferences.setMockInitialValues({
      _exploreKey: jsonEncode({
        'cards': [_cardJson('cached1', 'Cached Carla')],
        'next_cursor': null,
        'has_more': false,
      }),
    });

    final gate = Completer<void>();
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore') {
          await gate.future;
          return http.Response(
            jsonEncode({
              'cards': [_cardJson('fresh1', 'Fresh Fiona')],
              'next_cursor': null,
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('no', 404);
      }),
    );

    final router = GoRouter(
      initialLocation: '/explore',
      routes: [
        GoRoute(
          path: '/explore',
          builder: (_, __) =>
              ExploreScreen(apiClient: api, cacheUid: _uid),
        ),
        GoRoute(
          path: '/profile/user/:uid',
          builder: (_, __) => const Scaffold(body: Text('PROFILE PAGE')),
        ),
        GoRoute(
          path: '/dm/:threadId',
          builder: (_, __) => const Scaffold(body: Text('DM')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    // Let the cache read land while the network fetch is still gated.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Cached Carla'), findsWidgets);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Fresh Fiona'), findsWidgets);
    expect(find.textContaining('Cached Carla'), findsNothing);

    // The fresh page replaced the cached one on disk.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_exploreKey), contains('fresh1'));
  });

  testWidgets('Plan paints the cached snapshot while /usage is in flight, '
      'then the fresh load swaps in', (tester) async {
    SharedPreferences.setMockInitialValues({
      _planKey: jsonEncode({
        'status': const SubscriptionStatus(
          planName: 'Pro',
          productId: 'ayma_pro_monthly',
        ).toMap(),
        'plans': [
          const PlanOption(
            name: 'Pro',
            productId: 'ayma_pro_monthly',
            price: 'CACHED_PRICE',
            blurb: 'b',
            credits: 100,
          ).toMap(),
        ],
        'usage': const UsageSummary(
          total: 10,
          features: {},
          creditsRemaining: 4242,
        ).toMap(),
        'trial': null,
      }),
    });

    final gate = Completer<void>();
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/usage') {
          await gate.future;
          return http.Response(jsonEncode(_usageJson()), 200);
        }
        return http.Response('no', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: PlanScreen(service: _FakeRc(), api: api, cacheUid: _uid)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The cached snapshot painted — no blocking loader despite /usage
    // still being in flight.
    expect(find.textContaining('CACHED_PRICE'), findsWidgets);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('FRESH_PRICE'), findsWidgets);
    expect(find.textContaining('CACHED_PRICE'), findsNothing);
  });

  testWidgets('Chat paints the cached conversation while history is in '
      'flight, then the fresh page swaps in and is persisted',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      _chatKey: jsonEncode({
        'messages': [
          {
            'role': 'user',
            'text': 'cached hello from me',
            'created_at': '2026-11-01T10:00:00.000Z',
          },
          {
            'role': 'ayma',
            'text': 'cached reply from Ayma',
            'created_at': '2026-11-01T10:01:00.000Z',
          },
        ],
      }),
    });

    final gate = Completer<void>();
    final auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: _uid),
    );
    final api = ApiClient(
      auth: auth,
      httpClient: MockClient((req) async {
        if (req.url.path == '/chat/history') {
          await gate.future;
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'role': 'ayma',
                  'text': 'fresh reply from Ayma',
                  'created_at': '2026-11-02T10:01:00.000Z',
                },
              ],
              'next_before': null,
            }),
            200,
            headers: _jsonUtf8,
          );
        }
        return http.Response('{}', 200, headers: _jsonUtf8);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(apiClient: api, auth: auth)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The cached conversation is on screen — not the full-screen loader —
    // even though the history fetch has not answered yet.
    expect(find.text('cached reply from Ayma'), findsOneWidget);
    expect(find.text('cached hello from me'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('fresh reply from Ayma'), findsOneWidget);
    expect(find.text('cached reply from Ayma'), findsNothing);

    // The fresh page replaced the cached one on disk.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_chatKey), contains('fresh reply from Ayma'));
  });
}
