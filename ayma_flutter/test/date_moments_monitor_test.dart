import 'package:ayma_flutter/services/date_moments_monitor.dart';
import 'package:ayma_flutter/services/date_plan.dart';
import 'package:ayma_flutter/services/location_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles(this._enabled);
  final bool _enabled;
  @override
  Future<bool> dateMomentsEnabled() async => _enabled;
}

class _FakeLocation extends LocationService {
  const _FakeLocation(this._here);
  final ({double lat, double lng})? _here;
  @override
  Future<({double lat, double lng})?> currentLatLng() async => _here;
}

/// Counts step-in fires in place of a DmService (no Firebase).
class _FakeFire {
  int fired = 0;
  Future<bool> call(String threadId, String messageId, String otherName) async {
    fired++;
    return true;
  }
}

DatePlan _plan({
  String status = 'both_approved',
  bool momentFired = false,
  double? lat = 37.3382,
  double? lng = -121.8863,
}) =>
    DatePlan.tryParse({
      'status': status,
      'place_name': 'Sakura Sushi',
      'address': '1 Main St',
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      'time_label': 'Fri at 8 PM',
      'starts_at': '2026-11-13T20:00:00+00:00',
      'approvals': {'me': true, 'them': true},
      'moment_fired': momentFired,
    })!;

Future<bool> _run({
  required bool enabled,
  required ({double lat, double lng})? here,
  DatePlan? plan,
  required _FakeFire fire,
}) {
  final monitor = DateMomentsMonitor(
    fire: fire.call,
    profiles: _FakeProfiles(enabled),
    location: _FakeLocation(here),
  );
  return monitor.maybeFire(
    threadId: 'me__them',
    messageId: 'card1',
    plan: plan ?? _plan(),
    otherName: 'Sofia',
  );
}

void main() {
  test('does not fire when the toggle is off (default)', () async {
    final fire = _FakeFire();
    final fired = await _run(
        enabled: false, here: (lat: 37.3382, lng: -121.8863), fire: fire);
    expect(fired, isFalse);
    expect(fire.fired, 0);
  });

  test('does not fire when location is unavailable (permission denied)',
      () async {
    final fire = _FakeFire();
    final fired = await _run(enabled: true, here: null, fire: fire);
    expect(fired, isFalse);
    expect(fire.fired, 0);
  });

  test('does not fire when the plan is not both-approved', () async {
    final fire = _FakeFire();
    final fired = await _run(
        enabled: true,
        here: (lat: 37.3382, lng: -121.8863),
        plan: _plan(status: 'partially_approved'),
        fire: fire);
    expect(fired, isFalse);
    expect(fire.fired, 0);
  });

  test('does not fire when it already fired', () async {
    final fire = _FakeFire();
    final fired = await _run(
        enabled: true,
        here: (lat: 37.3382, lng: -121.8863),
        plan: _plan(momentFired: true),
        fire: fire);
    expect(fired, isFalse);
    expect(fire.fired, 0);
  });

  test('does not fire when the plan has no coordinates', () async {
    final fire = _FakeFire();
    final fired = await _run(
        enabled: true,
        here: (lat: 37.3382, lng: -121.8863),
        plan: _plan(lat: null, lng: null),
        fire: fire);
    expect(fired, isFalse);
    expect(fire.fired, 0);
  });

  test('fires once when opted in and at the place', () async {
    final fire = _FakeFire();
    final fired = await _run(
        enabled: true, here: (lat: 37.3382, lng: -121.8863), fire: fire);
    expect(fired, isTrue);
    expect(fire.fired, 1);
  });

  test('does not fire when far from the place', () async {
    final fire = _FakeFire();
    final fired =
        await _run(enabled: true, here: (lat: 37.5, lng: -121.8863), fire: fire);
    expect(fired, isFalse);
    expect(fire.fired, 0);
  });
}
