import 'dart:io' show Platform;

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

  /// Whether "Always" (background) location is already granted — the
  /// authorization the always-on arrival geofence + location log need. `false`
  /// for while-in-use or denied.
  Future<bool> hasBackgroundPermission() async {
    try {
      return await Geolocator.checkPermission() == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// Request "Always" (background) location permission, escalating from
  /// while-in-use if needed. Returns whether it ends up granted. Never throws.
  /// Granting here does NOT enable any feature — the Privacy toggles are the
  /// opt-in; this only unlocks the background stream once a toggle is on.
  Future<bool> ensureBackgroundPermission() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      // Android grants while-in-use first; a second request escalates to
      // always (or routes the user to settings). iOS prompts for "Always"
      // directly off the always-and-when-in-use description.
      if (permission == LocationPermission.whileInUse) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// An always-on background position stream for the arrival geofence and the
  /// opt-in location log. On Android it runs a foreground service (required
  /// for background location from API 26+); on iOS it allows background
  /// updates. Only start this when a Privacy toggle is on AND
  /// [hasBackgroundPermission] is true — the caller owns that gate.
  Stream<({double lat, double lng})> backgroundPositionStream({
    int distanceFilterMeters = 50,
  }) {
    final LocationSettings settings;
    if (Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Ayma',
          notificationText:
              'Watching for your planned date so Ayma can step in.',
          notificationChannelName: 'Date moments',
          enableWakeLock: true,
          setOngoing: false,
        ),
      );
    } else if (Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
        allowBackgroundLocationUpdates: true,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        activityType: ActivityType.other,
      );
    } else {
      settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      );
    }
    return Geolocator.getPositionStream(locationSettings: settings)
        .map((p) => (lat: p.latitude, lng: p.longitude));
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
