import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FreshData.state', () {
    test('live when server data with no pending writes', () {
      const f = FreshData<int>(data: 1);
      expect(f.state, FreshnessState.live);
    });

    test('syncing when hasPendingWrites', () {
      const f = FreshData<int>(data: 1, hasPendingWrites: true);
      expect(f.state, FreshnessState.syncing);
    });

    test('syncing when refreshing over existing data', () {
      const f = FreshData<int>(data: 1, refreshing: true);
      expect(f.state, FreshnessState.syncing);
    });

    test('stale when from cache with no pending writes', () {
      const f = FreshData<int>(data: 1, isFromCache: true);
      expect(f.state, FreshnessState.stale);
    });

    test('stale when error but prior data kept', () {
      final f = FreshData<int>(data: 1, error: Exception('net'), isFromCache: true);
      expect(f.state, FreshnessState.stale);
    });

    test('refused when error and no data', () {
      final f = FreshData<int>(error: Exception('net'));
      expect(f.state, FreshnessState.refused);
    });

    test('syncing when no data yet and no error', () {
      const f = FreshData<int>();
      expect(f.state, FreshnessState.syncing);
    });
  });

  group('FreshData.fromApi', () {
    test('success is live', () {
      final f = FreshData.fromApi(data: [1, 2]);
      expect(f.state, FreshnessState.live);
      expect(f.data, [1, 2]);
    });

    test('failure with prior data is stale', () {
      final f = FreshData.fromApi(
        data: [1],
        error: Exception('down'),
        fromPrior: true,
      );
      expect(f.state, FreshnessState.stale);
    });

    test('failure with nothing is refused', () {
      final f = FreshData.fromApi(error: Exception('down'));
      expect(f.state, FreshnessState.refused);
    });

    test('refreshing over prior is syncing', () {
      final f = FreshData.fromApi(data: [1], refreshing: true, fromPrior: true);
      // refreshing wins over fromPrior
      expect(f.state, FreshnessState.syncing);
    });
  });

  group('FreshData.mergeMeta', () {
    test('ORs pessimistic flags', () {
      const a = FreshData<int>(data: 1, isFromCache: true);
      const b = FreshData<int>(data: 2, hasPendingWrites: true);
      final m = FreshData.mergeMeta(data: 'x', a: a, b: b);
      expect(m.data, 'x');
      expect(m.isFromCache, isTrue);
      expect(m.hasPendingWrites, isTrue);
      expect(m.state, FreshnessState.syncing);
    });
  });
}
