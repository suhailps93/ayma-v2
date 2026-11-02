import 'package:ayma_flutter/models/boot_config.dart';
import 'package:ayma_flutter/services/report_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('BootConfig Model & ReportCache Integration', () {
    test('serializes and deserializes BootConfig properly', () {
      final config = BootConfig(
        uid: 'user_123',
        sessionMode: 'active',
        entryRoute: '/chat',
        cachedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
        biometricConsentRequiredHint: true,
        ageBlockedHint: false,
        recoveryRequiredHint: false,
      );

      final json = config.toJson();
      final parsed = BootConfig.fromJson(json);

      expect(parsed.uid, equals('user_123'));
      expect(parsed.sessionMode, equals('active'));
      expect(parsed.entryRoute, equals('/chat'));
      expect(parsed.biometricConsentRequiredHint, isTrue);
      expect(parsed.ageBlockedHint, isFalse);
      expect(parsed.recoveryRequiredHint, isFalse);
      expect(parsed.isStale, isFalse);
    });

    test('isStale returns true when older than 7 days', () {
      final eightDaysAgo = DateTime.now()
          .subtract(const Duration(days: 8))
          .millisecondsSinceEpoch;
      final config = BootConfig(
        uid: 'u_old',
        sessionMode: 'active',
        entryRoute: '/',
        cachedAtEpochMs: eightDaysAgo,
      );

      expect(config.isStale, isTrue);
    });

    test('ReportCache reads and writes BootConfig, ignoring stale caches',
        () async {
      SharedPreferences.setMockInitialValues({});
      final cache = ReportCache.instance;
      cache.resetForTest();

      final now = DateTime.now().millisecondsSinceEpoch;
      final fresh = BootConfig(
        uid: 'user_fresh',
        sessionMode: 'active',
        entryRoute: '/preboarding',
        cachedAtEpochMs: now,
      );

      await cache.writeBootConfig('user_fresh', fresh);
      final readBack = await cache.readBootConfig('user_fresh');
      expect(readBack, isNotNull);
      expect(readBack!.entryRoute, equals('/preboarding'));

      // Also verifies backward compatibility readBootRoute
      final routeString = await cache.readBootRoute('user_fresh');
      expect(routeString, equals('/preboarding'));

      // Stale cache returns null
      final stale = BootConfig(
        uid: 'user_stale',
        sessionMode: 'active',
        entryRoute: '/',
        cachedAtEpochMs: DateTime.now()
            .subtract(const Duration(days: 9))
            .millisecondsSinceEpoch,
      );
      await cache.writeBootConfig('user_stale', stale);
      final readStale = await cache.readBootConfig('user_stale');
      expect(readStale, isNull);
    });

    test('ReportCache falls back to legacy boot_route when boot_config is missing',
        () async {
      SharedPreferences.setMockInitialValues({'boot_route:legacy_u': '/shell'});
      final cache = ReportCache.instance;
      cache.resetForTest();

      final config = await cache.readBootConfig('legacy_u');
      expect(config, isNotNull);
      expect(config!.entryRoute, equals('/shell'));
      expect(config.sessionMode, equals('active'));
    });
  });
}
