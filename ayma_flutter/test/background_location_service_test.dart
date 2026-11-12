import 'package:ayma_flutter/services/background_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

ActiveDatePlan _plan({
  String threadId = 't1',
  String messageId = 'm1',
  double? lat = 37.3382,
  double? lng = -121.8863,
}) =>
    ActiveDatePlan(
      threadId: threadId,
      messageId: messageId,
      placeName: 'Sakura Sushi',
      lat: lat,
      lng: lng,
    );

void main() {
  group('hits (geofence)', () {
    test('includes a plan within the radius, excludes one outside', () {
      final near = _plan();
      final far = _plan(threadId: 't2', lat: 37.5, lng: -121.8863);
      final out = BackgroundLocationService.hits(
          37.3382, -121.8863, [near, far], 150);
      expect(out.map((p) => p.threadId), ['t1']);
    });

    test('ignores a plan without coordinates', () {
      final noCoords = _plan(lat: null, lng: null);
      expect(
        BackgroundLocationService.hits(37.3382, -121.8863, [noCoords], 150),
        isEmpty,
      );
    });
  });

  group('onPosition dispatch', () {
    test('logs when the log is on and fires an arrived-at plan', () async {
      final logged = <({double lat, double lng})>[];
      final fired = <String>[];
      final svc = BackgroundLocationService(
        logLocation: (lat, lng) async {
          logged.add((lat: lat, lng: lng));
          return true;
        },
        fireMoment: (t, m) async => fired.add('$t/$m'),
      )..debugSetState(
          logEnabled: true,
          dateMomentsEnabled: true,
          activePlans: [_plan()],
        );

      await svc.onPosition((lat: 37.3382, lng: -121.8863));
      // Let the unawaited log future settle.
      await Future<void>.delayed(Duration.zero);

      expect(logged, hasLength(1));
      expect(fired, ['t1/m1']);
    });

    test('fires each plan only once across repeated positions', () async {
      final fired = <String>[];
      final svc = BackgroundLocationService(
        fireMoment: (t, m) async => fired.add('$t/$m'),
      )..debugSetState(dateMomentsEnabled: true, activePlans: [_plan()]);

      await svc.onPosition((lat: 37.3382, lng: -121.8863));
      await svc.onPosition((lat: 37.3382, lng: -121.8863));
      expect(fired, ['t1/m1']); // once, not twice
    });

    test('does nothing at all when the master switch is off', () async {
      final logged = <int>[];
      final fired = <int>[];
      final svc = BackgroundLocationService(
        logLocation: (lat, lng) async {
          logged.add(1);
          return true;
        },
        fireMoment: (t, m) async => fired.add(1),
      )..debugSetState(
          masterOn: false,
          logEnabled: true,
          dateMomentsEnabled: true,
          activePlans: [_plan()],
        );

      await svc.onPosition((lat: 37.3382, lng: -121.8863));
      await Future<void>.delayed(Duration.zero);
      expect(logged, isEmpty);
      expect(fired, isEmpty);
    });

    test('does not fire date moments when only the log is on', () async {
      final fired = <int>[];
      final svc = BackgroundLocationService(
        logLocation: (lat, lng) async => true,
        fireMoment: (t, m) async => fired.add(1),
      )..debugSetState(
          logEnabled: true,
          dateMomentsEnabled: false,
          activePlans: [_plan()],
        );
      await svc.onPosition((lat: 37.3382, lng: -121.8863));
      expect(fired, isEmpty);
    });
  });

  group('wantStream gating', () {
    test('master or background off halts the stream', () {
      final svc = BackgroundLocationService();
      svc.debugSetState(
          masterOn: true, backgroundOn: true, logEnabled: true);
      expect(svc.debugWantStream, isTrue);
      svc.debugSetState(backgroundOn: false);
      expect(svc.debugWantStream, isFalse);
      svc.debugSetState(backgroundOn: true, masterOn: false);
      expect(svc.debugWantStream, isFalse);
    });

    test('no stream when nothing is opted in', () {
      final svc = BackgroundLocationService()
        ..debugSetState(
            masterOn: true,
            backgroundOn: true,
            logEnabled: false,
            dateMomentsEnabled: false,
            activePlans: const []);
      expect(svc.debugWantStream, isFalse);
    });
  });
}
