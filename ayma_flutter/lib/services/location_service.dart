import 'package:geocoding/geocoding.dart' as gc;
import 'package:geolocator/geolocator.dart';

/// Device location → a human "City, Country" string for the profile location
/// field (ARCHITECTURE.md §4.3). Callers fall back to typed/voice entry when
/// this returns `null` (permission denied, services off, no fix).
class LocationService {
  const LocationService();

  Future<String?> detectCity() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    final Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      );
    } catch (_) {
      return null;
    }

    try {
      final places = await gc.Geocoding().placemarkFromCoordinates(
        pos.latitude,
        pos.longitude,
      );
      return formatPlacemark(places.isEmpty ? null : places.first);
    } catch (_) {
      return null;
    }
  }

  /// Ask the OS for location permission at app start (mirrors the
  /// notification-permission ask). Returns whether it is granted. Safe to
  /// call on every start: when already granted it just reports true, and a
  /// denial never throws. Granting here does NOT enable any feature — the
  /// "Date moments" toggle is the opt-in.
  Future<bool> ensurePermission() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// Whether location permission is already granted (no prompt).
  Future<bool> hasPermission() async {
    try {
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// The device's current (lat, lng), or `null` when location is off, denied
  /// or no fix is available. Used by the date step-in's arrival check.
  Future<({double lat, double lng})?> currentLatLng() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      if (!await hasPermission()) return null;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Metres between two lat/lng points (Haversine via Geolocator).
  static double distanceMeters(
          double lat1, double lng1, double lat2, double lng2) =>
      Geolocator.distanceBetween(lat1, lng1, lat2, lng2);

  /// City-preferring formatter, extracted so it can be unit-tested without a
  /// device. `null` when there's nothing usable.
  static String? formatPlacemark(gc.Placemark? p) {
    if (p == null) return null;
    final city = [p.locality, p.subAdministrativeArea, p.administrativeArea]
        .where((s) => s != null && s.trim().isNotEmpty)
        .map((s) => s!.trim())
        .cast<String>()
        .firstOrNull;
    final country = p.country?.trim();
    if (city == null && (country == null || country.isEmpty)) return null;
    if (city == null) return country;
    if (country == null || country.isEmpty) return city;
    return '$city, $country';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
