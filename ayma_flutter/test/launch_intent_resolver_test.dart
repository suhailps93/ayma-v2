import 'package:ayma_flutter/core/dag/launch_intent_resolver.dart';
import 'package:ayma_flutter/core/dag/startup_dag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LaunchIntentResolver', () {
    test('Resolves IconLaunchIntent when notification data is null or empty',
        () async {
      final intent1 = await LaunchIntentResolver.extract(
        fcmPayloadGetter: () async => null,
        nativeChannelGetter: () async => null,
      );
      expect(intent1, isA<IconLaunchIntent>());

      final intent2 = LaunchIntentResolver.classify({});
      expect(intent2, isA<IconLaunchIntent>());
    });

    test('Resolves PaywallDeepLinkIntent when deep link is plan or trial', () {
      final intentPlan =
          LaunchIntentResolver.classify({'deep_link': 'plan'});
      expect(intentPlan, isA<PaywallDeepLinkIntent>());
      expect((intentPlan as PaywallDeepLinkIntent).targetPath,
          equals('/profile/plan'));

      final intentTrial =
          LaunchIntentResolver.classify({'deep_link': 'trial'});
      expect(intentTrial, isA<PaywallDeepLinkIntent>());
      expect((intentTrial as PaywallDeepLinkIntent).targetPath,
          equals('/profile/usage/trial'));
    });

    test(
        'Resolves DmDeepLinkIntent when payload contains type: dm or profile/:uid',
        () {
      // 1. dm_thread link
      final intentThread = LaunchIntentResolver.classify(
          {'deep_link': 'dm_thread/sarah_u1'});
      expect(intentThread, isA<DmDeepLinkIntent>());
      expect((intentThread as DmDeepLinkIntent).threadId, equals('sarah_u1'));

      // 2. profile link
      final intentProfile =
          LaunchIntentResolver.classify({'deep_link': 'profile/user_99'});
      expect(intentProfile, isA<DmDeepLinkIntent>());
      expect((intentProfile as DmDeepLinkIntent).recipientUid,
          equals('user_99'));

      // 3. type: dm fallback
      final intentTypeDm = LaunchIntentResolver.classify(
          {'type': 'dm', 'sender_uid': 'sender_42'});
      expect(intentTypeDm, isA<DmDeepLinkIntent>());
      expect((intentTypeDm as DmDeepLinkIntent).recipientUid,
          equals('sender_42'));
    });

    test(
        'Dynamic promotion — verifies edge N11 -> N12 is dynamically added on paywall intent',
        () {
      final dag = StartupDAG();
      dag.addNode(StartupNode<void>(
        id: 'N11:revenuecat_init',
        action: (ctx) async {},
      ));
      dag.addNode(StartupNode<void>(
        id: 'N12:destination_routing',
        action: (ctx) async {},
      ));

      expect(dag.nodes['N12:destination_routing']!.dependencies, isEmpty);

      const paywallIntent =
          PaywallDeepLinkIntent(targetPath: '/profile/plan');
      LaunchIntentResolver.configureDAGForIntent(dag, paywallIntent);

      expect(
        dag.nodes['N12:destination_routing']!.dependencies,
        contains('N11:revenuecat_init'),
      );
    });
  });
}
