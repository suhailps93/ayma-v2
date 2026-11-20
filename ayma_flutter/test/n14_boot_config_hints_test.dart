import 'package:ayma_flutter/core/dag/startup_dag.dart';
import 'package:ayma_flutter/core/dag/startup_nodes.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/report_cache.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Startup audit §2.3 / directive 4: N14's background refresher used to write a
/// refreshed BootConfig WITHOUT the advisory gate hints the splash's
/// `_cacheEntryRoute` writes, so an N14 refresh erased them. This pins that N14
/// now carries all three (biometric / age / recovery) into the cached config.
class _FakeApi extends ApiClient {
  _FakeApi(this._result) : super(auth: MockFirebaseAuth());
  final BootstrapResult _result;

  @override
  Future<BootstrapResult> bootstrap({
    required String sessionId,
    List<Map<String, String>> recentTurns = const [],
    String practiceReturnSessionId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async =>
      _result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> primeCache() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ReportCache.instance.resetForTest();
    ReportCache.instance.hydrateFromPrefs(prefs);
    await ReportCache.instance.ensureReady();
  }

  test('N14 refresh carries the biometric/age/recovery hints into BootConfig',
      () async {
    await primeCache();
    final api = _FakeApi(const BootstrapResult(
      sessionMode: 'active',
      livekitUrl: '',
      livekitToken: '',
      room: '',
      biometricConsentRequired: true,
    ));
    final node = StartupNodes.createBackgroundRefresherNode(apiClient: api);
    await node.execute(DAGContext()..put<User?>('auth_user', MockUser(uid: 'u14')));

    final config = await ReportCache.instance.readBootConfig('u14');
    expect(config, isNotNull);
    expect(config!.biometricConsentRequiredHint, isTrue,
        reason: 'the biometric hint must survive an N14 refresh');
    expect(config.ageBlockedHint, isFalse);
    expect(config.recoveryRequiredHint, isFalse);
    expect(config.sessionMode, 'active');
  });

  test('N14 refresh carries ageBlocked when the server reports it', () async {
    await primeCache();
    final api = _FakeApi(const BootstrapResult(
      sessionMode: '',
      livekitUrl: '',
      livekitToken: '',
      room: '',
      ageBlocked: true,
    ));
    final node = StartupNodes.createBackgroundRefresherNode(apiClient: api);
    await node.execute(DAGContext()..put<User?>('auth_user', MockUser(uid: 'u15')));

    final config = await ReportCache.instance.readBootConfig('u15');
    expect(config, isNotNull);
    expect(config!.ageBlockedHint, isTrue);
    expect(config.biometricConsentRequiredHint, isFalse);
  });
}
