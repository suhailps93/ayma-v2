import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'location_service.dart';

/// One both-approved plan's arrival anchor, read from the per-user
/// `active_date_plans` index the backend maintains (so the geofence never has
/// to open or scan DM threads).
@immutable
class ActiveDatePlan {
  const ActiveDatePlan({
    required this.threadId,
    required this.messageId,
    required this.placeName,
    required this.lat,
    required this.lng,
  });

  final String threadId;
  final String messageId;
  final String placeName;
  final double? lat;
  final double? lng;

  bool get hasCoords => lat != null && lng != null;

  static double? _coord(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String && raw.trim().isNotEmpty) return double.tryParse(raw);
    return null;
  }

  factory ActiveDatePlan.fromMap(String threadId, Map<String, dynamic> m) =>
      ActiveDatePlan(
        threadId: (m['thread_id'] as String?) ?? threadId,
        messageId: (m['message_id'] as String?) ?? '',
        placeName: (m['place_name'] as String?) ?? '',
        lat: _coord(m['lat']),
        lng: _coord(m['lng']),
      );
}

/// Always-on background location for the date step-in and the opt-in location
/// log (founder decision 2026-11-12: BACKGROUND, geofence-based arrival — not
/// foreground-only).
///
/// It runs a single background GPS stream and, on each update, (1) logs the
/// visit when the location log is opted in, and (2) fires the date step-in for
/// any both-approved plan the device has arrived at. The stream only runs when
/// at least one of those is active AND the user granted "Always" location — so
/// nothing happens without the opt-in + permission. The server still owns the
/// step-in's time window + once-only guard and re-checks the log opt-in; a
/// false positive here cannot double-post, fire off-time, or log when off.
/// Logs one visit; returns whether the server stored it.
typedef LogLocationFn = Future<bool> Function(double lat, double lng);

/// Fires the date step-in for one plan.
typedef FireDateMomentFn = Future<void> Function(
    String threadId, String messageId);

class BackgroundLocationService {
  BackgroundLocationService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    ApiClient? api,
    this.location = const LocationService(),
    LogLocationFn? logLocation,
    FireDateMomentFn? fireMoment,
    this.arrivalRadiusMeters = 150,
  })  : _authOverride = auth,
        _firestoreOverride = firestore,
        _apiOverride = api,
        _logLocationFn = logLocation,
        _fireMomentFn = fireMoment;

  /// App-wide instance, started on sign-in and stopped on sign-out
  /// (`main.dart`). Lazily constructed, so it never touches Firebase before
  /// init.
  static final BackgroundLocationService instance = BackgroundLocationService();

  final FirebaseAuth? _authOverride;
  final FirebaseFirestore? _firestoreOverride;
  final ApiClient? _apiOverride;
  final LocationService location;
  final LogLocationFn? _logLocationFn;
  final FireDateMomentFn? _fireMomentFn;
  final double arrivalRadiusMeters;

  // Lazy so a unit test that only exercises the dispatch logic never
  // constructs a Firebase singleton (mirrors ProfileService's lazy bindings).
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseFirestore get _firestore =>
      _firestoreOverride ?? FirebaseFirestore.instance;
  ApiClient? _apiLazy;
  ApiClient get _api => _apiOverride ?? (_apiLazy ??= ApiClient());

  LogLocationFn get _logLocation => _logLocationFn ?? _api.logLocation;
  FireDateMomentFn get _fireMoment =>
      _fireMomentFn ?? (t, m) => _api.datePlanMoment(t, m, '').then((_) {});

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _plansSub;
  StreamSubscription<({double lat, double lng})>? _positionSub;

  bool _masterOn = true;
  bool _backgroundOn = true;
  bool _logEnabled = false;
  bool _dateMomentsEnabled = false;
  List<ActiveDatePlan> _activePlans = const [];
  bool _streamRunning = false;
  // Plans already asked to fire this run, so one arrival makes one call.
  final Set<String> _fired = <String>{};

  /// Begin watching the opt-in toggles + active plans for the signed-in user.
  /// Idempotent and safe to call on every app start; a signed-out state is a
  /// no-op. The GPS stream itself only starts once a toggle is on and
  /// background permission is granted.
  void start() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || _profileSub != null) return;
    _profileSub = _firestore.doc('users/$uid/profile/main').snapshots().listen(
      (snap) {
        final data = snap.data() ?? const {};
        // Master/background default ON (not killed) unless explicitly false.
        _masterOn = data['location_master_enabled'] != false;
        _backgroundOn = data['location_background_enabled'] != false;
        _logEnabled = data['location_log_enabled'] == true;
        _dateMomentsEnabled = data['date_moments_enabled'] == true;
        _reconcile();
      },
      onError: (_) {},
    );
    _plansSub = _firestore
        .collection('users/$uid/active_date_plans')
        .snapshots()
        .listen(
      (snap) {
        _activePlans = snap.docs
            .map((d) => ActiveDatePlan.fromMap(d.id, d.data()))
            .where((p) => p.hasCoords && p.messageId.isNotEmpty)
            .toList();
        _reconcile();
      },
      onError: (_) {},
    );
  }

  /// Stop all watching and the GPS stream (e.g. on sign-out).
  Future<void> stop() async {
    await _profileSub?.cancel();
    await _plansSub?.cancel();
    await _positionSub?.cancel();
    _profileSub = _plansSub = null;
    _positionSub = null;
    _streamRunning = false;
    _fired.clear();
    _activePlans = const [];
  }

  /// The background GPS stream runs only when the master switch is on, the
  /// background switch is on, and at least one feature needs it. Master off or
  /// background off halts it entirely (kill switches, §4.3a).
  bool get _wantStream =>
      _masterOn &&
      _backgroundOn &&
      (_logEnabled || (_dateMomentsEnabled && _activePlans.isNotEmpty));

  Future<void> _reconcile() async {
    if (_wantStream) {
      if (_streamRunning) return;
      if (!await location.hasBackgroundPermission()) return;
      _streamRunning = true;
      _positionSub =
          location.backgroundPositionStream().listen(onPosition, onError: (_) {
        _streamRunning = false;
      });
    } else {
      if (!_streamRunning) return;
      await _positionSub?.cancel();
      _positionSub = null;
      _streamRunning = false;
      _fired.clear();
    }
  }

  /// Which active plans the device has arrived at (within [arrivalRadiusMeters]
  /// of a plan's coordinates). Pure, so the geofence is unit-tested without GPS.
  @visibleForTesting
  static List<ActiveDatePlan> hits(
    double lat,
    double lng,
    Iterable<ActiveDatePlan> plans,
    double radiusMeters,
  ) {
    return plans.where((p) {
      if (!p.hasCoords) return false;
      final metres =
          LocationService.distanceMeters(lat, lng, p.lat!, p.lng!);
      return metres <= radiusMeters;
    }).toList();
  }

  /// Handle one background position: log it (when opted in) and fire the
  /// step-in for any arrived-at plan. Never throws; every call is best-effort.
  @visibleForTesting
  Future<void> onPosition(({double lat, double lng}) pos) async {
    if (!_masterOn) return; // master kill switch: do nothing with any fix
    if (_logEnabled) {
      // The server re-checks the opt-in before storing (and runs the proactive
      // routine check + push).
      unawaited(_logLocation(pos.lat, pos.lng).catchError((_) => false));
    }
    if (!_dateMomentsEnabled) return;
    for (final plan in hits(pos.lat, pos.lng, _activePlans, arrivalRadiusMeters)) {
      final key = '${plan.threadId}/${plan.messageId}';
      if (_fired.contains(key)) continue;
      _fired.add(key);
      try {
        await _fireMoment(plan.threadId, plan.messageId);
      } catch (_) {
        // Allow a later arrival to retry if this attempt failed outright.
        _fired.remove(key);
      }
    }
  }

  /// Test seam: set the in-memory state the stream callbacks would set.
  @visibleForTesting
  void debugSetState({
    bool? masterOn,
    bool? backgroundOn,
    bool? logEnabled,
    bool? dateMomentsEnabled,
    List<ActiveDatePlan>? activePlans,
  }) {
    if (masterOn != null) _masterOn = masterOn;
    if (backgroundOn != null) _backgroundOn = backgroundOn;
    if (logEnabled != null) _logEnabled = logEnabled;
    if (dateMomentsEnabled != null) _dateMomentsEnabled = dateMomentsEnabled;
    if (activePlans != null) _activePlans = activePlans;
  }

  @visibleForTesting
  bool get debugWantStream => _wantStream;
}
