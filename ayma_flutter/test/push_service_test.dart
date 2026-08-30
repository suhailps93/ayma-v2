import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/push_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

class _FakeFcm implements FcmTokens {
  _FakeFcm({this.permission = true, this.token = 'tok-1'});

  bool permission;
  String? token;
  final _refresh = StreamController<String>.broadcast();
  bool deleted = false;

  @override
  Future<bool> ensurePermission() async => permission;

  @override
  Future<String?> currentToken() async => token;

  @override
  Stream<String> tokenRefreshes() => _refresh.stream;

  @override
  Future<void> deleteToken() async => deleted = true;
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
}
