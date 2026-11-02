import 'dart:async';

import 'package:ayma_flutter/core/dag/startup_dag.dart';
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

    // Regression: P0 boot crash — Firebase init order after startup flattening.
    //
    // main() does its Firebase-dependent setup (PushService →
    // FirebaseMessaging.instance, the FirebaseAuth.authStateChanges listener,
    // push.listenForTaps) AFTER `await dag.run(targetNodes: {'N8:...'})`,
    // relying on the DAG guaranteeing Firebase.initializeApp (N7) has run by
    // then. If that invariant breaks, main() touches Firebase before
    // [core/no-app] is resolved and the app hangs on the splash. These tests
    // lock the invariant.
    // The invariant: NO Firebase-dependent node may run before N7. Rather than
    // a hand-maintained list of Firebase nodes (which missed N5 and N11 the
    // first time — their Firebase access is hidden in a constructor:
    // AccentColorController→ProfileService→FirebaseAuth.instance and
    // ApiClient()→FirebaseAuth.instance), this inverts the check: every node is
    // required to depend transitively on N7 UNLESS it is in the explicitly
    // audited "Firebase-free" allowlist. A new node that touches Firebase and
    // forgets the N7 edge therefore fails this test by default.
    test('every node transitively depends on N7:firebase_core except the '
        'audited Firebase-free nodes', () {
      final dag = StartupNodes.buildDefaultDAG();

      Set<String> transitiveDeps(String id) {
        final out = <String>{};
        void walk(String node) {
          for (final dep in dag.nodes[node]!.dependencies) {
            if (out.add(dep)) walk(dep);
          }
        }

        walk(id);
        return out;
      }

      // Audited as touching NO Firebase at action time. If a node is added
      // here, it must genuinely make no Firebase/RevenueCat-via-Firebase call
      // (directly or through a constructor/singleton it first touches).
      const firebaseFreeNodes = {
        'N1:engine_binding', // WidgetsFlutterBinding only
        'N2:orientation_lock', // SystemChrome only
        'N3:crashlytics_fatal', // installs handlers; Firebase calls deferred+guarded
        'N4:prefs_preload', // SharedPreferences only
        'N7:firebase_core', // the gate itself
      };

      for (final id in dag.nodes.keys) {
        if (firebaseFreeNodes.contains(id)) continue;
        expect(
          transitiveDeps(id),
          contains('N7:firebase_core'),
          reason: '$id is not in the audited Firebase-free allowlist, so it '
              'must depend (transitively) on N7:firebase_core. If it truly '
              'touches no Firebase, add it to firebaseFreeNodes with a reason.',
        );
      }

      // Guard the allowlist itself: the two nodes whose Firebase access hides
      // in a constructor (the original miss) must NOT be treated as free.
      expect(firebaseFreeNodes, isNot(contains('N5:ui_controllers')));
      expect(firebaseFreeNodes, isNot(contains('N11:revenuecat_init')));
    });

    test('run(targetNodes: {N8}) returns only after N7:firebase_core has run '
        '(the invariant main() relies on before registering push/auth '
        'listeners)', () async {
      // Mirror the REAL dependency wiring (copied from buildDefaultDAG) into an
      // instrumented DAG whose nodes only record execution order — so we
      // exercise the actual graph shape without initializing real Firebase.
      final real = StartupNodes.buildDefaultDAG();
      final completionOrder = <String>[];
      final mirror = StartupDAG();
      for (final node in real.nodes.values) {
        mirror.addNode(
          StartupNode<void>(
            id: node.id,
            dependencies: node.dependencies,
            critical: node.critical,
            action: (ctx) async {
              // In the real graph N9 blocks until the main() auth listener
              // fires notifyAuthSessionRestored — which only happens AFTER
              // `dag.run({N8})` returns. N9 is not on the path to N8, so the
              // run target must still resolve with N9 outstanding. Model that.
              if (node.id == 'N9:auth_session_restore') {
                await Completer<void>().future; // never completes
              }
              completionOrder.add(node.id);
            },
          ),
        );
      }

      await mirror.run(targetNodes: {'N8:first_frame_mount'});

      expect(
        completionOrder,
        contains('N7:firebase_core'),
        reason: 'Firebase must be initialized before run-to-N8 returns',
      );
      expect(
        completionOrder.indexOf('N7:firebase_core'),
        lessThan(completionOrder.indexOf('N8:first_frame_mount')),
        reason: 'N7:firebase_core must complete before N8:first_frame_mount',
      );
    });

    test('full DAG run executes N7:firebase_core before every '
        'Firebase-dependent node (regression: N5/N11 ran pre-N7)', () async {
      // Mirror the real wiring (dependencies copied from buildDefaultDAG) with
      // recorder-only actions and let the FULL graph run to completion, so we
      // observe the real execution order every node sees at boot. N9 must
      // complete here (otherwise its dependents never run), so no node hangs.
      final real = StartupNodes.buildDefaultDAG();
      final completionOrder = <String>[];
      final mirror = StartupDAG();
      for (final node in real.nodes.values) {
        mirror.addNode(
          StartupNode<void>(
            id: node.id,
            dependencies: node.dependencies,
            critical: node.critical,
            action: (ctx) async {
              completionOrder.add(node.id);
            },
          ),
        );
      }

      await mirror.run();

      expect(completionOrder.length, equals(real.nodes.length));

      // Same audited allowlist as the structural test: everything else must
      // have observed N7 complete before it ran.
      const firebaseFreeNodes = {
        'N1:engine_binding',
        'N2:orientation_lock',
        'N3:crashlytics_fatal',
        'N4:prefs_preload',
        'N7:firebase_core',
      };
      final n7Index = completionOrder.indexOf('N7:firebase_core');
      expect(n7Index, greaterThanOrEqualTo(0));
      for (final id in real.nodes.keys) {
        if (firebaseFreeNodes.contains(id)) continue;
        expect(
          completionOrder.indexOf(id),
          greaterThan(n7Index),
          reason: '$id (Firebase-dependent) ran before N7:firebase_core',
        );
      }
    });
  });
}
