import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug build prefers the test key', () {
    expect(
      RevenueCatService.selectKey(
          isDebug: true, testKey: 'test_k', platformKey: 'prod_k'),
      'test_k',
    );
  });

  test('release build ignores the test key when a production key exists', () {
    expect(
      RevenueCatService.selectKey(
          isDebug: false, testKey: 'test_k', platformKey: 'prod_k'),
      'prod_k',
    );
  });

  test('release build with only the test key fails loudly', () {
    expect(
      () => RevenueCatService.selectKey(
          isDebug: false, testKey: 'test_k', platformKey: ''),
      throwsA(isA<StateError>()),
    );
  });

  test('release build with no keys stays disabled', () {
    expect(
      RevenueCatService.selectKey(isDebug: false, testKey: '', platformKey: ''),
      '',
    );
  });
}
