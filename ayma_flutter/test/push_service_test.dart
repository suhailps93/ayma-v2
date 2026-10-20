import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/services/push_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

class _FakeFcm implements FcmTokens {
  _FakeFcm({
    this.permission = true,
    this.token = 'tok-1',
    this.initialTap,
  });

  bool permission;
  String? token;
  final _refresh = StreamController<String>.broadcast();
  final _taps = StreamController<Map<String, dynamic>>.broadcast();
  bool deleted = false;

  /// The `data` payload of the notification that "cold-started" the app, if
  /// any — returned once by [initialTapData], like the real plugin.
  Map<String, dynamic>? initialTap;

  @override
  Future<bool> ensurePermission() async => permission;

  @override
  Future<String?> currentToken() async => token;

  @override
  Stream<String> tokenRefreshes() => _refresh.stream;

  @override
  Future<void> deleteToken() async => deleted = true;

  @override
  Future<Map<String, dynamic>?> initialTapData() async => initialTap;

  @override
  Stream<Map<String, dynamic>> tapsWhileRunning() => _taps.stream;

  /// Test helper: simulate tapping a push notification while the app is
  /// already running (`onMessageOpenedApp`).
  void tap(Map<String, dynamic> data) => _taps.add(data);
}

ApiClient _api(void Function(http.Request) onCall) {
  final mock = MockClient((req) async {
    onCall(req);
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(
      httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  test('syncToken registers the current token', () async {
    final calls = <String>[];
    final svc = PushService(
      tokens: _FakeFcm(token: 'device-abc'),
      apiClient: _api((r) => calls.add('${r.method} ${r.url.path} ${r.body}')),
    );

    await svc.syncToken();

    expect(calls, hasLength(1));
    expect(calls.single, contains('POST /notifications/token'));
    expect(calls.single, contains('device-abc'));
  });

  test('syncToken does nothing when permission is denied', () async {
    final calls = <String>[];
    final svc = PushService(
      tokens: _FakeFcm(permission: false),
      apiClient: _api((r) => calls.add(r.url.path)),
    );

    await svc.syncToken();

    expect(calls, isEmpty);
  });

  test('a refreshed token is re-registered', () async {
    final calls = <String>[];
    final fcm = _FakeFcm(token: 'first');
    final svc = PushService(
      tokens: fcm,
      apiClient: _api((r) => calls.add(r.body)),
    );

    await svc.syncToken();
    fcm._refresh.add('second');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(calls.where((b) => b.contains('first')), hasLength(1));
    expect(calls.where((b) => b.contains('second')), hasLength(1));

    // Re-emitting the same token is a no-op.
    fcm._refresh.add('second');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.where((b) => b.contains('second')), hasLength(1));
  });

  test('clearToken unregisters then deletes the device token', () async {
    final calls = <String>[];
    final fcm = _FakeFcm(token: 'bye');
    final svc = PushService(
      tokens: fcm,
      apiClient: _api((r) => calls.add('${r.url.path} ${r.body}')),
    );

    await svc.clearToken();

    expect(calls.single, contains('/notifications/token/remove'));
    expect(calls.single, contains('bye'));
    expect(fcm.deleted, isTrue);
  });

  group('listenForTaps', () {
    test('a cold-start tap routes using the deep_link resolver', () async {
      final fcm = _FakeFcm(initialTap: {'deep_link': 'match_request/a__bob'});
      final svc = PushService(tokens: fcm, apiClient: _api((_) {}));
      final routed = <String>[];

      await svc.listenForTaps(
        navigate: routed.add,
        resolveRoute: (link) => '/resolved/$link',
      );

      expect(routed, ['/resolved/match_request/a__bob']);
    });

    test('no cold-start message means no navigation', () async {
      final svc = PushService(tokens: _FakeFcm(), apiClient: _api((_) {}));
      final routed = <String>[];

      await svc.listenForTaps(navigate: routed.add, resolveRoute: (l) => l);

      expect(routed, isEmpty);
    });

    test('a tap while the app is already running also routes', () async {
      final fcm = _FakeFcm();
      final svc = PushService(tokens: fcm, apiClient: _api((_) {}));
      final routed = <String>[];

      await svc.listenForTaps(
        navigate: routed.add,
        resolveRoute: (link) => '/resolved/$link',
      );
      fcm.tap({'deep_link': 'matches'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(routed, ['/resolved/matches']);
    });

    test('a DM notification tap opens /dm/<pairKey> in every app state',
        () async {
      String resolve(String l) => deepLinkToRoute(l, myUid: 'founder');
      final fcm = _FakeFcm(
          initialTap: {'type': 'dm', 'deep_link': 'dm_thread/dillu__founder'});
      final svc = PushService(tokens: fcm, apiClient: _api((_) {}));
      final routed = <String>[];

      await svc.listenForTaps(navigate: routed.add, resolveRoute: resolve);
      fcm.tap({'type': 'dm', 'deep_link': 'dm_thread/dillu__founder'});
      fcm.tap({'type': 'dm', 'sender_uid': 'dillu'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(routed, [
        '/dm/dillu__founder',
        '/dm/dillu__founder',
        '/dm/dillu__founder',
      ]);
    });

    test('a tap with no deep_link data is ignored', () async {
      final fcm = _FakeFcm();
      final svc = PushService(tokens: fcm, apiClient: _api((_) {}));
      final routed = <String>[];

      await svc.listenForTaps(navigate: routed.add, resolveRoute: (l) => l);
      fcm.tap(<String, dynamic>{});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(routed, isEmpty);
    });
  });
}
