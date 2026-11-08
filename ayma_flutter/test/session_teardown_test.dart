// Regression tests for the systemic navigation & auth teardown fix
// (ghost-header root fix, R2-C6 / R2-C7). Reproduces, at unit level, the
// privacy-critical requirement that on sign-out / account-switch every
// in-memory singleton carrying Account A's state is purged and the router
// subtree is forced to rebuild — so none of it can linger into Account B.
//
// Deliberately Firebase-free: `AuthSessionState` is a pure `ChangeNotifier`
// and `teardownSession` wraps every transport-touching step, so the whole
// suite runs with no initialized Firebase Core (no `[core/no-app]`).

import 'package:ayma_flutter/core/app_recovery.dart';
import 'package:ayma_flutter/core/session_teardown.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/auth_session_state.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/services/biometric_consent.dart';
import 'package:ayma_flutter/services/credits_balance.dart';
import 'package:ayma_flutter/services/deep_dive_activity.dart';
import 'package:ayma_flutter/services/deep_link_queue.dart';
import 'package:ayma_flutter/services/dev_panel_session.dart';
import 'package:ayma_flutter/services/match_activity.dart';
import 'package:ayma_flutter/services/match_report_cache.dart';
import 'package:ayma_flutter/services/tab_prefetch_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

MatchReport _ghostReport(String id) => MatchReport(
      matchId: id,
      score: 0.9,
      dimensions: const [],
      shared: const [],
      tensions: const [],
      missing: const [],
      explanation: 'ghost',
      otherUid: 'other',
      otherName: 'Other',
      otherPhoto: '',
      myPhoto: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthSessionState (pure ChangeNotifier, no Firebase)', () {
    setUp(() => AuthSessionState.instance.clear());

    test('instantiable and readable without Firebase initialized', () {
      // Reaching .instance at all here would throw [core/no-app] if the class
      // imported firebase_auth. It does not — this test suite never calls
      // Firebase.initializeApp().
      expect(AuthSessionState.instance.signedIn, isFalse);
      expect(AuthSessionState.instance.uid, isNull);
    });

    test('update(signedIn, uid) sets state and notifies', () {
      var notifications = 0;
      void listener() => notifications++;
      AuthSessionState.instance.addListener(listener);
      addTearDown(() => AuthSessionState.instance.removeListener(listener));

      AuthSessionState.instance.update(signedIn: true, uid: 'uid-A');
      expect(AuthSessionState.instance.signedIn, isTrue);
      expect(AuthSessionState.instance.uid, 'uid-A');
      expect(notifications, 1);
    });

    test('a no-op update does not notify', () {
      AuthSessionState.instance.update(signedIn: true, uid: 'uid-A');
      var notifications = 0;
      void listener() => notifications++;
      AuthSessionState.instance.addListener(listener);
      addTearDown(() => AuthSessionState.instance.removeListener(listener));

      AuthSessionState.instance.update(signedIn: true, uid: 'uid-A');
      expect(notifications, 0);
    });

    test('clear() resets to signed-out and notifies', () {
      AuthSessionState.instance.update(signedIn: true, uid: 'uid-A');
      var notifications = 0;
      void listener() => notifications++;
      AuthSessionState.instance.addListener(listener);
      addTearDown(() => AuthSessionState.instance.removeListener(listener));

      AuthSessionState.instance.clear();
      expect(AuthSessionState.instance.signedIn, isFalse);
      expect(AuthSessionState.instance.uid, isNull);
      expect(notifications, 1);
    });
  });

  group('teardownSession purges every cross-account singleton', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AuthSessionState.instance.update(signedIn: true, uid: 'uid-A');
    });

    void seedAccountAState() {
      AymaSession.instance.store.clear();
      AymaSession.instance.store.addPending('ghost A transcript');
      TabPrefetchCoordinator.instance.debugSeed(
        minis: const {'u1': MiniProfile(name: 'Ghost A', photo: '')},
      );
      CreditsBalance.instance.remaining.value = 42;
      MatchReportCache.instance.put(_ghostReport('m-ghost'));
      DeepDiveActivity.instance.searching.value = const {'d1'};
      DeepDiveActivity.instance.failed.value = const {'d2'};
      MatchActivity.instance.recalculating.value = const {'m1'};
      AppContext.instance.set(screen: 'profile', subjectName: 'Ghost A');
      RecoveryRequiredState.instance.markRequired();
      BiometricConsentState.instance.markRequired();
      DevPanelSession.instance.unlocked.value = true;
    }

    void expectAccountAStateGone() {
      expect(AymaSession.instance.store.turns, isEmpty,
          reason: 'chat transcript must be purged');
      expect(TabPrefetchCoordinator.instance.takeMiniProfiles(), isEmpty,
          reason: 'prefetched mini-profiles must be purged');
      expect(TabPrefetchCoordinator.instance.takeExplorePage(), isNull,
          reason: 'prefetched explore page must be purged');
      expect(CreditsBalance.instance.remaining.value, isNull,
          reason: "Account A's credit balance must not survive");
      expect(MatchReportCache.instance.get('m-ghost'), isNull,
          reason: 'cached match report must be purged');
      expect(DeepDiveActivity.instance.searching.value, isEmpty);
      expect(DeepDiveActivity.instance.failed.value, isEmpty);
      expect(MatchActivity.instance.recalculating.value, isEmpty);
      expect(DeepLinkQueue.instance.pendingPostAuthIntent, isNull,
          reason: 'stashed deep-link intent must not drain into next account');
      expect(AppContext.instance.current.value.screen, '',
          reason: 'screen context must reset');
      expect(RecoveryRequiredState.instance.required, isFalse);
      expect(BiometricConsentState.instance.required, isFalse);
      expect(DevPanelSession.instance.unlocked.value, isFalse,
          reason: 'developer panel must relock');
    }

    test('sign-out (isSwitch:false) purges singletons, bumps epoch, '
        'clears auth state', () {
      seedAccountAState();
      final epochBefore = appRecoveryEpoch.value;

      teardownSession(isSwitch: false);

      expectAccountAStateGone();
      expect(appRecoveryEpoch.value, epochBefore + 1,
          reason: 'epoch bump forces the router/navigator subtree to rebuild');
      expect(AuthSessionState.instance.signedIn, isFalse,
          reason: 'router-facing auth state must flip to signed-out');
      expect(AuthSessionState.instance.uid, isNull);
    });

    test('account switch (isSwitch:true) purges singletons and bumps epoch',
        () {
      seedAccountAState();
      final epochBefore = appRecoveryEpoch.value;

      teardownSession(isSwitch: true);

      expectAccountAStateGone();
      expect(appRecoveryEpoch.value, epochBefore + 1);
      expect(AuthSessionState.instance.signedIn, isFalse);
    });
  });
}
