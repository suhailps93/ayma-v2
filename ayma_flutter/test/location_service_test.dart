import 'dart:async';

import 'package:ayma_flutter/services/location_service.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_test/flutter_test.dart';

Placemark _pm({String? locality, String? subAdmin, String? admin, String? country}) =>
    Placemark(
      locality: locality,
      subAdministrativeArea: subAdmin,
      administrativeArea: admin,
      country: country,
    );

void main() {
  test('prefers locality, then falls back through admin areas', () {
    expect(
      LocationService.formatPlacemark(
          _pm(locality: 'Lisbon', country: 'Portugal')),
      'Lisbon, Portugal',
    );
    expect(
      LocationService.formatPlacemark(
          _pm(subAdmin: 'Travis County', country: 'USA')),
      'Travis County, USA',
    );
    expect(
      LocationService.formatPlacemark(_pm(admin: 'Bavaria', country: 'Germany')),
      'Bavaria, Germany',
    );
  });

  test('handles missing pieces', () {
    expect(LocationService.formatPlacemark(_pm(country: 'France')), 'France');
    expect(LocationService.formatPlacemark(_pm(locality: 'Berlin')), 'Berlin');
    expect(LocationService.formatPlacemark(_pm()), isNull);
    expect(LocationService.formatPlacemark(null), isNull);
  });

  group('LocationService.ensurePermission', () {
    test('returns true when permission is already whileInUse without requesting',
        () async {
      var requested = false;
      final svc = LocationService(
        checkPermissionFn: () async => LocationPermission.whileInUse,
        requestPermissionFn: () async {
          requested = true;
          return LocationPermission.whileInUse;
        },
      );
      expect(await svc.ensurePermission(), isTrue);
      expect(requested, isFalse);
    });

    test('returns false without requesting when permission is deniedForever',
        () async {
      var requested = false;
      final svc = LocationService(
        checkPermissionFn: () async => LocationPermission.deniedForever,
        requestPermissionFn: () async {
          requested = true;
          return LocationPermission.denied;
        },
      );
      expect(await svc.ensurePermission(), isFalse);
      expect(requested, isFalse);
    });

    test('requests permission when denied and returns true on grant', () async {
      var requested = false;
      final svc = LocationService(
        checkPermissionFn: () async => LocationPermission.denied,
        requestPermissionFn: () async {
          requested = true;
          return LocationPermission.whileInUse;
        },
      );
      expect(await svc.ensurePermission(), isTrue);
      expect(requested, isTrue);
    });

    test('returns false when request returns denied', () async {
      final svc = LocationService(
        checkPermissionFn: () async => LocationPermission.denied,
        requestPermissionFn: () async => LocationPermission.denied,
      );
      expect(await svc.ensurePermission(), isFalse);
    });

    test('times out and returns false if request hangs (empty grantResults)',
        () async {
      final completer = Completer<LocationPermission>();
      final svc = LocationService(
        checkPermissionFn: () async => LocationPermission.denied,
        requestPermissionFn: () => completer.future,
      );
      expect(
        await svc.ensurePermission(timeout: const Duration(milliseconds: 50)),
        isFalse,
      );
    });
  });
}
