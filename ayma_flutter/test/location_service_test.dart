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
}
