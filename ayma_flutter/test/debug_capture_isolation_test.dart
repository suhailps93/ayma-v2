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
    DebugCaptureIsolation.disabled.value = false;
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

  group('DebugCaptureIsolation prefs cache', () {
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

    test('a missing flag doc means isolation stays on', () async {
      final db = FakeFirebaseFirestore();
      await DebugCaptureIsolation.refresh(db);
      expect(DebugCaptureIsolation.disabled.value, isFalse);
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
