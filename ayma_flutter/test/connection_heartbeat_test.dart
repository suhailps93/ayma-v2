import 'dart:async';

import 'package:ayma_flutter/services/connection_heartbeat.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ConnectionClassifier', () {
    test('starts ok', () {
      expect(ConnectionClassifier().state, ConnectionQuality.ok);
    });

    test('one failure -> weak, second consecutive failure -> offline', () {
      final c = ConnectionClassifier();
      c.record(ProbeOutcome.failure);
      expect(c.state, ConnectionQuality.weak);
      c.record(ProbeOutcome.failure);
      expect(c.state, ConnectionQuality.offline);
    });

    test('recovery needs 2 consecutive good probes (offline -> weak -> ok)',
        () {
      final c = ConnectionClassifier()
        ..record(ProbeOutcome.failure)
        ..record(ProbeOutcome.failure);
      expect(c.state, ConnectionQuality.offline);
      c.record(ProbeOutcome.good);
      expect(c.state, ConnectionQuality.weak);
      c.record(ProbeOutcome.good);
      expect(c.state, ConnectionQuality.ok);
    });

    test('one slow probe stays ok, two consecutive slow -> weak', () {
      final c = ConnectionClassifier();
      c.record(ProbeOutcome.slow);
      expect(c.state, ConnectionQuality.ok);
      c.record(ProbeOutcome.slow);
      expect(c.state, ConnectionQuality.weak);
    });

    test('a good probe between slows resets the slow streak', () {
      final c = ConnectionClassifier();
      c.record(ProbeOutcome.slow);
      c.record(ProbeOutcome.good);
      c.record(ProbeOutcome.slow);
      expect(c.state, ConnectionQuality.ok);
    });

    test('a slow probe between goods resets the recovery streak', () {
      final c = ConnectionClassifier()
        ..record(ProbeOutcome.failure)
        ..record(ProbeOutcome.failure);
      c.record(ProbeOutcome.good);
      expect(c.state, ConnectionQuality.weak);
      c.record(ProbeOutcome.slow);
      expect(c.state, ConnectionQuality.weak);
      // Still needs two consecutive goods from here.
      c.record(ProbeOutcome.good);
      expect(c.state, ConnectionQuality.weak);
      c.record(ProbeOutcome.good);
      expect(c.state, ConnectionQuality.ok);
    });

    test('intermittent failures hold weak and never reach offline', () {
      final c = ConnectionClassifier();
      for (var i = 0; i < 6; i++) {
        c.record(ProbeOutcome.failure);
        expect(c.state, ConnectionQuality.weak);
        c.record(ProbeOutcome.good);
        expect(c.state, ConnectionQuality.weak);
      }
    });

    test('a slow probe from offline steps up to weak (server reachable)',
        () {
      final c = ConnectionClassifier()
        ..record(ProbeOutcome.failure)
        ..record(ProbeOutcome.failure);
      c.record(ProbeOutcome.slow);
      expect(c.state, ConnectionQuality.weak);
    });

    test('a lone failure from weak stays weak', () {
      final c = ConnectionClassifier()
        ..record(ProbeOutcome.slow)
        ..record(ProbeOutcome.slow);
      expect(c.state, ConnectionQuality.weak);
      c.record(ProbeOutcome.failure);
      expect(c.state, ConnectionQuality.weak);
    });

    test('reset returns to ok', () {
      final c = ConnectionClassifier()
        ..record(ProbeOutcome.failure)
        ..record(ProbeOutcome.failure);
      c.reset();
      expect(c.state, ConnectionQuality.ok);
    });
  });

  group('metered interval selection', () {
    test('wifi/ethernet probe at the base interval', () {
      expect(
        ConnectionHeartbeat.intervalFor([ConnectivityResult.wifi]),
        ConnectionHeartbeat.probeInterval,
      );
      expect(
        ConnectionHeartbeat.intervalFor([ConnectivityResult.ethernet]),
        ConnectionHeartbeat.probeInterval,
      );
      expect(
        ConnectionHeartbeat.intervalFor(
            [ConnectivityResult.vpn, ConnectivityResult.wifi]),
        ConnectionHeartbeat.probeInterval,
      );
    });

    test('cellular-only (metered proxy) stretches the interval', () {
      expect(
        ConnectionHeartbeat.isMeteredConnection([ConnectivityResult.mobile]),
        isTrue,
      );
      expect(
        ConnectionHeartbeat.intervalFor([ConnectivityResult.mobile]),
        ConnectionHeartbeat.meteredProbeInterval,
      );
      expect(
        ConnectionHeartbeat.meteredProbeInterval >
            ConnectionHeartbeat.probeInterval,
        isTrue,
      );
    });

    test('no usable connection stretches the interval (regain is event-driven)',
        () {
      expect(
        ConnectionHeartbeat.intervalFor([ConnectivityResult.none]),
        ConnectionHeartbeat.meteredProbeInterval,
      );
    });

    test('unknown (empty) fails open to the base interval', () {
      expect(ConnectionHeartbeat.isMeteredConnection([]), isFalse);
      expect(
        ConnectionHeartbeat.intervalFor([]),
        ConnectionHeartbeat.probeInterval,
      );
    });
  });

  group('ConnectionHeartbeat probe path', () {
    test('probeNow feeds outcomes through the classifier', () async {
      final script = [ProbeOutcome.failure, ProbeOutcome.failure];
      final hb = ConnectionHeartbeat(probe: () async => script.removeAt(0));
      expect(hb.state, ConnectionQuality.ok);
      await hb.probeNow();
      expect(hb.state, ConnectionQuality.weak);
      await hb.probeNow();
      expect(hb.state, ConnectionQuality.offline);
      expect(hb.probeCount, 2);
    });

    test('a second probeNow while one is in flight is skipped', () async {
      final gate = Completer<ProbeOutcome>();
      final hb = ConnectionHeartbeat(probe: () => gate.future);
      final first = hb.probeNow();
      final second = hb.probeNow();
      await second;
      gate.complete(ProbeOutcome.good);
      await first;
      expect(hb.probeCount, 1);
      expect(hb.state, ConnectionQuality.ok);
    });

    test('OS reports none -> failure outcome without any HTTP request',
        () async {
      var httpCalls = 0;
      final hb = ConnectionHeartbeat(
        checkConnectivity: () async => [ConnectivityResult.none],
        httpClient: MockClient((_) async {
          httpCalls++;
          return http.Response('{}', 200);
        }),
      );
      await hb.probeNow();
      await hb.probeNow();
      expect(hb.state, ConnectionQuality.offline);
      expect(httpCalls, 0);
    });

    test('non-200 probe response counts as a failure', () async {
      final hb = ConnectionHeartbeat(
        checkConnectivity: () async => [ConnectivityResult.wifi],
        httpClient: MockClient((_) async => http.Response('no', 500)),
      );
      await hb.probeNow();
      expect(hb.state, ConnectionQuality.weak);
      await hb.probeNow();
      expect(hb.state, ConnectionQuality.offline);
    });

    test('a slow real probe (over the 4s budget) classifies as slow, and two '
        'slow probes flip the state to weak', () async {
      final hb = ConnectionHeartbeat(
        checkConnectivity: () async => [ConnectivityResult.wifi],
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 4500));
          return http.Response('{}', 200);
        }),
      );
      await hb.probeNow();
      expect(hb.lastProbeOutcome, ProbeOutcome.slow);
      expect(hb.lastProbeElapsed!.inMilliseconds, greaterThanOrEqualTo(4000));
      expect(hb.state, ConnectionQuality.ok);
      await hb.probeNow();
      expect(hb.lastProbeOutcome, ProbeOutcome.slow);
      expect(hb.state, ConnectionQuality.weak);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('start() keeps probing on its interval (timer chain re-arms)',
        () async {
      final hb = ConnectionHeartbeat(
        probe: () async => ProbeOutcome.good,
        connectivityChanges: const Stream.empty(),
        probeIntervalOverride: const Duration(milliseconds: 100),
      );
      try {
        hb.start();
        // Initial probe + at least two timer ticks.
        for (var i = 0; i < 200 && hb.probeCount < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(hb.probeCount, greaterThanOrEqualTo(3));
        expect(hb.state, ConnectionQuality.ok);
      } finally {
        hb.stop();
      }
    });

    test('a hung connectivity read cannot wedge the probe: it times out '
        'and the HTTP probe still classifies', () async {
      final hb = ConnectionHeartbeat(
        // The platform read never completes (the 2026-11-05 emulator
        // wedge). Without the read bound, probeNow would never return
        // and every later probe would no-op behind the in-flight flag.
        checkConnectivity: () => Completer<List<ConnectivityResult>>().future,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await hb.probeNow().timeout(const Duration(seconds: 10));
      expect(hb.probeCount, 1);
      expect(hb.lastProbeOutcome, ProbeOutcome.good);
      expect(hb.state, ConnectionQuality.ok);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('start/stop lifecycle arms and disarms without leaking', () async {
      final hb = ConnectionHeartbeat(
        probe: () async => ProbeOutcome.good,
        connectivityChanges: const Stream.empty(),
      );
      try {
        expect(hb.isStarted, isFalse);
        hb.start();
        expect(hb.isStarted, isTrue);
        // The immediate start-up probe completes on its own.
        for (var i = 0; i < 200 && hb.probeCount < 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(hb.probeCount, 1);
        expect(hb.state, ConnectionQuality.ok);
      } finally {
        hb.stop();
      }
      expect(hb.isStarted, isFalse);
    });
  });
}
