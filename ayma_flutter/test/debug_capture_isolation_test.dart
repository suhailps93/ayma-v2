import 'dart:async';

import 'package:ayma_flutter/services/debug_capture_isolation.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
