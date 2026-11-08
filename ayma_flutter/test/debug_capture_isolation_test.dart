// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:ayma_flutter/core/dag/startup_dag.dart';
import 'package:ayma_flutter/core/dag/startup_nodes.dart';
import 'package:ayma_flutter/services/debug_capture_isolation.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DelayedDocRef implements DocumentReference<Map<String, dynamic>> {
  final DocumentReference<Map<String, dynamic>> _inner;
  final Duration delay;
  final void Function(String path)? onGet;

  _DelayedDocRef(this._inner, {this.delay = Duration.zero, this.onGet});

  @override
  String get path => _inner.path;

  @override
  String get id => _inner.id;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      _inner.set(data, options);

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    onGet?.call(path);
    return _inner.get(options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedCollectionRef implements CollectionReference<Map<String, dynamic>> {
  final CollectionReference<Map<String, dynamic>> _inner;
  final Duration delay;
  final void Function(String path)? onGet;

  _DelayedCollectionRef(this._inner, {this.delay = Duration.zero, this.onGet});

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    final d = _inner.doc(path);
    return _DelayedDocRef(d, delay: delay, onGet: onGet);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedFirestore extends FakeFirebaseFirestore {
  final Duration delay;
  final void Function(String path)? onGet;

  _DelayedFirestore({this.delay = Duration.zero, this.onGet});

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    final inner = super.collection(collectionPath);
    return _DelayedCollectionRef(inner, delay: delay, onGet: onGet);
  }
}

/// Reads one named constraint out of the `optional` list the SDK emits in
/// [AudioCaptureOptions.toMediaConstraintsMap].
bool? optionalConstraint(Map<String, dynamic> map, String key) {
  final optional = map['optional'] as List<dynamic>?;
  if (optional == null) return null;
  for (final entry in optional) {
    final m = entry as Map<String, dynamic>;
    if (m.containsKey(key)) return m[key] as bool?;
  }
  return null;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DebugCaptureIsolation.resetForTesting();
  });

  group('DebugCaptureIsolation.parse', () {
    test('only a literal enabled:true disables isolation', () {
      expect(DebugCaptureIsolation.parse(null), isFalse);
      expect(DebugCaptureIsolation.parse({}), isFalse);
      expect(DebugCaptureIsolation.parse({'enabled': false}), isFalse);
      expect(DebugCaptureIsolation.parse({'enabled': 'true'}), isFalse);
      expect(DebugCaptureIsolation.parse({'enabled': 1}), isFalse);
      expect(DebugCaptureIsolation.parse({'enabled': true}), isTrue);
    });
  });

  group('DebugCaptureIsolation prefs cache & type resilience', () {
    test('loadFromPrefs applies the cached value, default off', () async {
      final prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isFalse);

      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': true});
      final prefs2 = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs2);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    test('loadFromPrefs handles string "true", "1", and number 1 gracefully',
        () async {
      // String 'true'
      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': 'true'});
      var prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isTrue);

      // String '1'
      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': '1'});
      prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isTrue);

      // Int 1
      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': 1});
      prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isTrue);

      // String 'false' resets to false
      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': 'false'});
      prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isFalse);
    });

    test('loadFromPrefs handles prefixed key flutter.debug_capture_isolation_disabled',
        () async {
      SharedPreferences.setMockInitialValues(
          {'flutter.debug_capture_isolation_disabled': true});
      final prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    test('refresh caches the Firestore flag and applies it in memory',
        () async {
      final db = FakeFirebaseFirestore();
      final ref =
          db.collection('app_config').doc('debug_capture_isolation');
      await ref.set({'enabled': true});
      await DebugCaptureIsolation.refresh(db);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
      expect((await SharedPreferences.getInstance())
          .getBool('debug_capture_isolation_disabled'), isTrue);

      await ref.set({'enabled': false});
      await DebugCaptureIsolation.refresh(db);
      expect(DebugCaptureIsolation.disabled.value, isFalse);
      expect((await SharedPreferences.getInstance())
          .getBool('debug_capture_isolation_disabled'), isFalse);
    });

    test('a missing flag doc does NOT overwrite existing seeded value', () async {
      // Seed local storage as Scout did
      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': true});
      final prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isTrue);

      // Missing Firestore doc
      final db = FakeFirebaseFirestore();
      await DebugCaptureIsolation.refresh(db);
      // Still true — not clobbered to false!
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });
  });

  group('DebugCaptureIsolation.readAtConnect', () {
    test('returns true at connect when seeded in SharedPreferences', () async {
      // Unhydrated start: value is false
      DebugCaptureIsolation.disabled.value = false;

      // Seed prefs key as Scout did on device
      SharedPreferences.setMockInitialValues(
          {'debug_capture_isolation_disabled': true});

      // Synchronous/async read at connect ensures ready and returns true
      final flagAtConnect = await DebugCaptureIsolation.readAtConnect();
      expect(flagAtConnect, isTrue);
      expect(DebugCaptureIsolation.disabled.value, isTrue);

      // Emitted constraints at connect will turn voiceIsolation OFF
      final constraints =
          captureAudioOptions(disableCaptureIsolation: flagAtConnect)
              .toMediaConstraintsMap();
      expect(optionalConstraint(constraints, 'voiceIsolation'), isFalse);
      expect(optionalConstraint(constraints, 'googNoiseSuppression'), isFalse);
    });

    test('returns true at connect when refreshed from Firestore', () async {
      DebugCaptureIsolation.disabled.value = false;
      final db = FakeFirebaseFirestore();
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      final flagAtConnect = await DebugCaptureIsolation.readAtConnect(db: db);
      expect(flagAtConnect, isTrue);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    test('returns true at connect even when an in-flight background refresh resolves',
        () async {
      DebugCaptureIsolation.disabled.value = false;
      final db = FakeFirebaseFirestore();
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      // Background N19 sync kicks off un-awaited
      unawaited(DebugCaptureIsolation.refresh(db));

      // Voice connects immediately while refresh is in flight
      final flagAtConnect = await DebugCaptureIsolation.readAtConnect();
      expect(flagAtConnect, isTrue);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    test('re-fetches updated flag from Firestore at connect after initial load',
        () async {
      final db = FakeFirebaseFirestore();
      final doc = db.collection('app_config').doc('debug_capture_isolation');

      // Initially false
      await doc.set({'enabled': false});
      await DebugCaptureIsolation.refresh(db);
      expect(DebugCaptureIsolation.disabled.value, isFalse);

      // Now flag is flipped to true in Firestore
      await doc.set({'enabled': true});

      // Session connect re-checks Firestore and picks up the flipped flag
      final flagAtConnect = await DebugCaptureIsolation.readAtConnect(db: db);
      expect(flagAtConnect, isTrue);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    test('refresh shares in-flight future between concurrent callers and clears on complete',
        () async {
      final db = FakeFirebaseFirestore();
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      final f1 = DebugCaptureIsolation.refresh(db);
      final f2 = DebugCaptureIsolation.refresh(db);
      expect(identical(f1, f2), isTrue);

      await Future.wait([f1, f2]);
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });
  });

  group('captureAudioOptions', () {
    test('flag off: default constraints request isolation', () {
      final map = captureAudioOptions(disableCaptureIsolation: false)
          .toMediaConstraintsMap();
      expect(optionalConstraint(map, 'voiceIsolation'), isTrue);
      expect(optionalConstraint(map, 'googNoiseSuppression'), isTrue);
      expect(optionalConstraint(map, 'echoCancellation'), isTrue);
      expect(optionalConstraint(map, 'autoGainControl'), isTrue);
    });

    test('flag on: isolation constraints off, echo/AGC untouched', () {
      final map = captureAudioOptions(disableCaptureIsolation: true)
          .toMediaConstraintsMap();
      expect(optionalConstraint(map, 'voiceIsolation'), isFalse);
      expect(optionalConstraint(map, 'googNoiseSuppression'), isFalse);
      expect(optionalConstraint(map, 'googNoiseSuppression2'), isFalse);
      expect(optionalConstraint(map, 'echoCancellation'), isTrue);
      expect(optionalConstraint(map, 'autoGainControl'), isTrue);
    });
  });

  group('DebugCaptureIsolation startup hydration and timeout resilience', () {
    test('startup N19 remote sync hydrates flag within budget when session is ready', () async {
      DebugCaptureIsolation.disabled.value = false;
      final db = FakeFirebaseFirestore();
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      final ctx = DAGContext();
      // Session restored:
      ctx.put<dynamic>('auth_user', null);

      final n19 = StartupNodes.createRemoteSyncNode(firestore: db);
      await n19.action(ctx);

      expect(DebugCaptureIsolation.disabled.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('debug_capture_isolation_disabled'), isTrue);
    });

    test('refresh accepts custom timeout budget and completes within budget', () async {
      DebugCaptureIsolation.disabled.value = false;
      final db = FakeFirebaseFirestore();
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      await DebugCaptureIsolation.refresh(db, timeout: const Duration(seconds: 4));
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    test('a timeout on refresh is non-fatal and leaves cached flag intact', () async {
      SharedPreferences.setMockInitialValues({'debug_capture_isolation_disabled': true});
      final prefs = await SharedPreferences.getInstance();
      DebugCaptureIsolation.loadFromPrefs(prefs);
      expect(DebugCaptureIsolation.disabled.value, isTrue);

      final db = FakeFirebaseFirestore();
      // Force refresh with 0 microsecond timeout so it immediately trips TimeoutException
      await DebugCaptureIsolation.refresh(db, timeout: Duration.zero);

      // Value remains intact (not reverted or cleared)
      expect(DebugCaptureIsolation.disabled.value, isTrue);
    });

    testWidgets(
        'startup N19 remote sync hydrates flag when network readiness takes 9s '
        '(regression: legacy 8s budget timed out before readiness on cold start)',
        (tester) async {
      DebugCaptureIsolation.disabled.value = false;
      final db = _DelayedFirestore(delay: const Duration(seconds: 9));
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      final ctx = DAGContext();
      ctx.put<dynamic>('auth_user', null);

      final n19 = StartupNodes.createRemoteSyncNode(firestore: db);
      final syncFuture = n19.action(ctx);

      // Advance past 9s to let the read complete under the new budget:
      await tester.pump(const Duration(seconds: 10));
      await syncFuture;

      expect(DebugCaptureIsolation.disabled.value, isTrue,
          reason:
              'Flag should be hydrated to true despite 9s network readiness delay');
    });

    testWidgets(
        'startup refresh retries and hydrates flag if first attempt times out '
        'before network is ready (regression: single attempt aborted on timeout)',
        (tester) async {
      DebugCaptureIsolation.disabled.value = false;
      var captureIsolationAttempts = 0;
      final db = _DelayedFirestore(
        delay: Duration.zero,
        onGet: (path) {
          if (path.contains('debug_capture_isolation')) {
            captureIsolationAttempts++;
            if (captureIsolationAttempts == 1) {
              throw TimeoutException(
                  'Simulated 8s timeout before ProviderInstaller finished');
            }
          }
        },
      );
      await db
          .collection('app_config')
          .doc('debug_capture_isolation')
          .set({'enabled': true});

      final ctx = DAGContext();
      ctx.put<dynamic>('auth_user', null);

      final n19 = StartupNodes.createRemoteSyncNode(firestore: db);
      final syncFuture = n19.action(ctx);

      // Advance time to allow retry delay to pass and retry to execute:
      await tester.pump(const Duration(seconds: 5));
      await syncFuture;

      expect(captureIsolationAttempts, greaterThanOrEqualTo(2),
          reason: 'Should have retried after initial timeout');
      expect(DebugCaptureIsolation.disabled.value, isTrue,
          reason: 'Flag should be hydrated on retry');
    });
  });
}
