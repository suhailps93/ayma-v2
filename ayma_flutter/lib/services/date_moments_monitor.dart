import 'date_plan.dart';
import 'location_service.dart';
import 'profile_service.dart';

/// Posts the date step-in for a card; returns whether it fired. Injected so
/// the monitor does not depend on (or construct) a DmService in tests.
typedef FireDateMoment = Future<bool> Function(
    String threadId, String messageId, String otherName);

/// Client-side arrival check for the date step-in (PIECE 1B).
///
/// For a both-approved, not-yet-fired plan that carries coordinates, when the
/// opted-in user's device is within [radiusMeters] of the place, it asks the
/// backend to post the step-in once. The backend owns the time window and the
/// once-only guard, so a false positive here cannot double-post or fire off
/// the plan time. No location is ever sent to the server, and no trail is
/// kept — the only record is the plan's `moment_fired` flag.
class DateMomentsMonitor {
  DateMomentsMonitor({
    required this.fire,
    ProfileService? profiles,
    this.location = const LocationService(),
    this.radiusMeters = 150,
  }) : _profiles = profiles ?? ProfileService();

  final FireDateMoment fire;
  final ProfileService _profiles;
  final LocationService location;
  final double radiusMeters;

  /// Try to fire the step-in. Returns true only when the backend actually
  /// posted it. Short-circuits (no location read) unless the plan is eligible
  /// and the user has opted in.
  Future<bool> maybeFire({
    required String threadId,
    required String messageId,
    required DatePlan plan,
    required String otherName,
  }) async {
    if (!plan.bothApproved || plan.momentFired || !plan.hasCoords) return false;
    // Master location kill switch overrides the feature opt-in (§4.3a).
    if (!await _profiles.locationMasterOn()) return false;
    if (!await _profiles.dateMomentsEnabled()) return false;
    final here = await location.currentLatLng();
    if (here == null) return false;
    final metres = LocationService.distanceMeters(
        here.lat, here.lng, plan.lat!, plan.lng!);
    if (metres > radiusMeters) return false;
    try {
      return await fire(threadId, messageId, otherName);
    } catch (_) {
      return false;
    }
  }
}
