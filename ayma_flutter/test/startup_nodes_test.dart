import 'package:ayma_flutter/core/dag/startup_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StartupNodes', () {
    test('buildDefaultDAG registers exactly all 19 nodes', () {
      final dag = StartupNodes.buildDefaultDAG();
      expect(dag.nodes.length, equals(19));

      const expectedNodeIds = [
        'N1:engine_binding',
        'N2:orientation_lock',
        'N3:crashlytics_fatal',
        'N4:prefs_preload',
        'N5:ui_controllers',
        'N6:launch_intent',
        'N7:firebase_core',
        'N8:first_frame_mount',
        'N9:auth_session_restore',
        'N10:boot_config_read',
        'N11:revenuecat_init',
        'N12:destination_routing',
        'N13:revenuecat_auth_bind',
        'N14:background_refresher',
        'N15:crashlytics_enable',
        'N16:push_token_sync',
        'N17:dev_observers',
        'N18:sentry_init',
        'N19:remote_sync',
      ];

      for (final id in expectedNodeIds) {
        expect(dag.nodes.containsKey(id), isTrue, reason: 'Missing node $id');
      }
    });

    test('validates graph edges and verifies zero cycles', () {
      final dag = StartupNodes.buildDefaultDAG();
      expect(() => dag.validate(), returnsNormally);
    });

    test('verifies key dependencies and critical node flags', () {
      final dag = StartupNodes.buildDefaultDAG();

      final n1 = dag.nodes['N1:engine_binding']!;
      expect(n1.critical, isTrue);
      expect(n1.dependencies, isEmpty);

      final n6 = dag.nodes['N6:launch_intent']!;
      expect(n6.dependencies, containsAll(['N1:engine_binding', 'N7:firebase_core']));

      final n8 = dag.nodes['N8:first_frame_mount']!;
      expect(n8.critical, isTrue);
      expect(
        n8.dependencies,
        containsAll([
          'N2:orientation_lock',
          'N3:crashlytics_fatal',
          'N5:ui_controllers',
          'N7:firebase_core',
        ]),
      );

      final n12 = dag.nodes['N12:destination_routing']!;
      expect(
        n12.dependencies,
        containsAll([
          'N6:launch_intent',
          'N8:first_frame_mount',
          'N9:auth_session_restore',
          'N10:boot_config_read',
        ]),
      );
    });
  });
}
