import 'package:ayma_flutter/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugAppEnvironmentOverride = null;
  });

  group('formatVersionString', () {
    test('formats staging build with version, build number, and staging tag', () {
      final s = formatVersionString(
        version: '1.30.0',
        buildNumber: '2264',
        environment: 'staging',
      );
      expect(s, '1.30.0+2264 · staging');
    });

    test('formats production build with version and build number only (no tag)', () {
      final s = formatVersionString(
        version: '1.30.0',
        buildNumber: '2264',
        environment: 'production',
      );
      expect(s, '1.30.0+2264');
    });

    test('omits tag when environment is phone-release or prod', () {
      expect(
        formatVersionString(
          version: '1.30.0',
          buildNumber: '2264',
          environment: 'phone-release',
        ),
        '1.30.0+2264',
      );
      expect(
        formatVersionString(
          version: '1.30.0',
          buildNumber: '2264',
          environment: 'prod',
        ),
        '1.30.0+2264',
      );
    });

    test('formats non-production custom environment tag', () {
      final s = formatVersionString(
        version: '1.30.0',
        buildNumber: '2264',
        environment: 'development',
      );
      expect(s, '1.30.0+2264 · development');
    });

    test('handles missing or empty build number', () {
      expect(
        formatVersionString(
          version: '1.30.0',
          buildNumber: '',
          environment: 'staging',
        ),
        '1.30.0 · staging',
      );
      expect(
        formatVersionString(
          version: '1.30.0',
          buildNumber: '',
          environment: 'production',
        ),
        '1.30.0',
      );
    });

    test('handles version containing plus sign without duplicating it', () {
      expect(
        formatVersionString(
          version: '1.30.0+2264',
          buildNumber: '2264',
          environment: 'staging',
        ),
        '1.30.0+2264 · staging',
      );
      expect(
        formatVersionString(
          version: '1.30.0+2264',
          buildNumber: '',
          environment: 'production',
        ),
        '1.30.0+2264',
      );
    });

    test('returns empty string if version is empty', () {
      expect(formatVersionString(version: '', buildNumber: '2264'), '');
    });

    test('uses debugAppEnvironmentOverride when environment is omitted', () {
      debugAppEnvironmentOverride = 'staging';
      expect(
        formatVersionString(version: '1.30.0', buildNumber: '2264'),
        '1.30.0+2264 · staging',
      );

      debugAppEnvironmentOverride = 'production';
      expect(
        formatVersionString(version: '1.30.0', buildNumber: '2264'),
        '1.30.0+2264',
      );
    });
  });

  group('isProductionEnvironment', () {
    test('returns true when environment is production, prod, or phone-release', () {
      debugAppEnvironmentOverride = 'production';
      expect(isProductionEnvironment, isTrue);

      debugAppEnvironmentOverride = 'prod';
      expect(isProductionEnvironment, isTrue);

      debugAppEnvironmentOverride = 'phone-release';
      expect(isProductionEnvironment, isTrue);
    });

    test('returns false when environment is staging or development', () {
      debugAppEnvironmentOverride = 'staging';
      expect(isProductionEnvironment, isFalse);

      debugAppEnvironmentOverride = 'development';
      expect(isProductionEnvironment, isFalse);
    });
  });
}
