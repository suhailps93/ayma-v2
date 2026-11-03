import 'package:ayma_flutter/core/dag/startup_dag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StartupDAG Engine', () {
    test('Executes nodes in exact topological order according to explicit edges',
        () async {
      final dag = StartupDAG();
      final executionOrder = <String>[];

      dag.addNode(StartupNode<String>(
        id: 'A',
        action: (ctx) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          executionOrder.add('A');
          return 'result_A';
        },
      ));

      dag.addNode(StartupNode<String>(
        id: 'B',
        dependencies: {'A'},
        action: (ctx) async {
          expect(ctx.get<String>('A'), equals('result_A'));
          executionOrder.add('B');
          return 'result_B';
        },
      ));

      dag.addNode(StartupNode<String>(
        id: 'C',
        dependencies: {'B'},
        action: (ctx) async {
          expect(ctx.get<String>('B'), equals('result_B'));
          executionOrder.add('C');
          return 'result_C';
        },
      ));

      final context = await dag.run();
      expect(executionOrder, equals(['A', 'B', 'C']));
      expect(context.get<String>('C'), equals('result_C'));
    });

    test('Concurrent execution — independent nodes execute in parallel',
        () async {
      final dag = StartupDAG();
      final startTimes = <String, DateTime>{};

      dag.addNode(StartupNode<void>(
        id: 'root',
        action: (ctx) async {},
      ));

      dag.addNode(StartupNode<void>(
        id: 'branch1',
        dependencies: {'root'},
        action: (ctx) async {
          startTimes['branch1'] = DateTime.now();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        },
      ));

      dag.addNode(StartupNode<void>(
        id: 'branch2',
        dependencies: {'root'},
        action: (ctx) async {
          startTimes['branch2'] = DateTime.now();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        },
      ));

      final sw = Stopwatch()..start();
      await dag.run();
      sw.stop();

      expect(startTimes.containsKey('branch1'), isTrue);
      expect(startTimes.containsKey('branch2'), isTrue);
      final delta = startTimes['branch1']!
          .difference(startTimes['branch2']!)
          .inMilliseconds
          .abs();
      // Both started concurrently (within 25ms of each other)
      expect(delta, lessThan(25));
      // Total runtime should be roughly ~60ms, not 120ms
      expect(sw.elapsedMilliseconds, lessThan(110));
    });

    test('Deadlock detection — throws StateError if a cyclic dependency is introduced',
        () async {
      final dag = StartupDAG();

      dag.addNode(StartupNode<void>(
        id: 'A',
        dependencies: {'B'},
        action: (ctx) async {},
      ));

      dag.addNode(StartupNode<void>(
        id: 'B',
        dependencies: {'C'},
        action: (ctx) async {},
      ));

      dag.addNode(StartupNode<void>(
        id: 'C',
        dependencies: {'A'},
        action: (ctx) async {},
      ));

      expect(() => dag.validate(), throwsA(isA<StateError>()));
      expect(() => dag.run(), throwsA(isA<StateError>()));
    });

    test(
        'Critical node failure propagates exception; non-critical node failure completes with fallback',
        () async {
      // 1. Non-critical failure with fallback
      final dag1 = StartupDAG();
      dag1.addNode(StartupNode<String>(
        id: 'non_critical',
        critical: false,
        fallback: 'fallback_val',
        action: (ctx) async => throw Exception('plumbing hiccup'),
      ));

      final ctx1 = await dag1.run();
      expect(ctx1.get<String>('non_critical'), equals('fallback_val'));

      // 2. Critical failure throws
      final dag2 = StartupDAG();
      dag2.addNode(StartupNode<void>(
        id: 'critical_node',
        critical: true,
        action: (ctx) async => throw StateError('fatal startup failure'),
      ));

      expect(() => dag2.run(), throwsA(isA<StateError>()));
    });

    test('Target nodes completion allows partial/staged DAG waits', () async {
      final dag = StartupDAG();
      var bgFinished = false;

      dag.addNode(StartupNode<void>(
        id: 'first_frame',
        action: (ctx) async {},
      ));

      dag.addNode(StartupNode<void>(
        id: 'background_work',
        dependencies: {'first_frame'},
        action: (ctx) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bgFinished = true;
        },
      ));

      final ctx = await dag.run(targetNodes: {'first_frame'});
      expect(ctx, isNotNull);
      expect(bgFinished, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(bgFinished, isTrue);
    });
  });
}
