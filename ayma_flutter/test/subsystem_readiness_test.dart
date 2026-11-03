import 'dart:async';

import 'package:ayma_flutter/models/boot_config.dart';
import 'package:ayma_flutter/screens/plan_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/meta_integrations.dart';
import 'package:ayma_flutter/services/report_cache.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControllableRc extends RevenueCatService {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> ensureReady({Duration timeout = const Duration(seconds: 4)}) =>
      gate.future;

  @override
  bool get enabled => gate.isCompleted;

  @override
  Future<List<PlanOption>> plans() async {
    await ensureReady();
    return RevenueCatService.fallbackPlans;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Subsystem Readiness Futures', () {
    test('RevenueCatService.ensureReady pauses concurrent callers until resolved',
        () async {
      final rc = RevenueCatService()..forceDeferredForTest();
      var planLoaded = false;

      // Caller starts awaiting plans before init completes
      final plansFuture = rc.plans().then((plans) {
        planLoaded = true;
        return plans;
      });

      // Assert that plansFuture is not resolved yet
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(planLoaded, isFalse);

      // Trigger initDeferred
      await rc.initDeferred();
      final plans = await plansFuture;

      expect(planLoaded, isTrue);
      expect(plans, isNotEmpty);
    });

    test('AuthService.ensureAuthReady pauses callers until user is restored',
        () async {
      final auth = MockFirebaseAuth();
      final authService = AuthService(auth: auth);
      var userRestored = false;

      final waitFuture = authService.ensureAuthReady().then((u) {
        userRestored = true;
        return u;
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(userRestored, isFalse);

      final mockUser = MockUser(uid: 'restored_user_42');
      authService.notifyAuthSessionRestored(mockUser);

      final resolved = await waitFuture;
      expect(userRestored, isTrue);
      expect(resolved?.uid, equals('restored_user_42'));
    });

    test('MetaIntegrations and ReportCache ensureReady resolve after hydration',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('meta_integrations_enabled', true);
      final now = DateTime.now().millisecondsSinceEpoch;
      final config = BootConfig(
        uid: 'u1',
        sessionMode: 'active',
        entryRoute: '/chat',
        cachedAtEpochMs: now,
      );

      ReportCache.instance.resetForTest();
      ReportCache.instance.hydrateFromPrefs(prefs);
      await ReportCache.instance.ensureReady();
      await ReportCache.instance.writeBootConfig('u1', config);

      final read = await ReportCache.instance.readBootConfig('u1');
      expect(read?.entryRoute, equals('/chat'));

      MetaIntegrations.loadFromPrefs(prefs);
      await MetaIntegrations.ensureReady();
      expect(MetaIntegrations.enabled.value, isTrue);
    });

    testWidgets(
        'PlanScreen shows loading state while RevenueCatService.ensureReady is pending',
        (tester) async {
      final controllableRc = _ControllableRc();
      final mockAuth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'u_plan'),
      );
      final api = ApiClient(
        auth: mockAuth,
        httpClient: MockClient((req) async {
          if (req.url.path.contains('usage')) {
            return http.Response(
                '{"credits_remaining": 10, "plan": "free"}', 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanScreen(service: controllableRc, api: api),
          ),
        ),
      );

      // Initial pump: PlanScreen is in loading state waiting on ensureReady
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Release ensureReady gate
      controllableRc.gate.complete();
      await tester.pumpAndSettle();

      // Content has rendered, loader is gone
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('FREE PLAN'), findsOneWidget);
    });
  });
}
