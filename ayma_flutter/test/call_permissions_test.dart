import 'package:ayma_flutter/services/call_permissions.dart';
import 'package:ayma_flutter/services/push_permission.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives every branch of [CallPermissions] without a real platform channel
/// — [PermissionGateway] is the seam `permission_handler` sits behind.
class _FakeGateway implements PermissionGateway {
  bool granted;
  int requestCalls = 0;
  int settingsCalls = 0;
  bool requestGrants;

  _FakeGateway({this.granted = false, this.requestGrants = true});

  @override
  Future<bool> isNotificationGranted() async => granted;

  @override
  Future<bool> requestNotification() async {
    requestCalls++;
    if (requestGrants) granted = true;
    return granted;
  }

  @override
  Future<bool> openAppSettings() async {
    settingsCalls++;
    return true;
  }
}

void main() {
  setUp(() => NotificationPermissionStore.clear());

  test('ensureCallStartPermissions requests when not yet granted', () async {
    final gateway = _FakeGateway(granted: false);
    final permissions = CallPermissions(gateway: gateway);

    await permissions.ensureCallStartPermissions();

    expect(gateway.requestCalls, 1);
    expect(gateway.granted, isTrue);
  });

  test('ensureCallStartPermissions leaves it denied when the user declines',
      () async {
    final gateway = _FakeGateway(granted: false, requestGrants: false);
    final permissions = CallPermissions(gateway: gateway);

    await permissions.ensureCallStartPermissions();

    expect(gateway.requestCalls, 1);
    expect(gateway.granted, isFalse);
  });

  test('ensureCallStartPermissions skips the request when already granted',
      () async {
    final gateway = _FakeGateway(granted: true);
    final permissions = CallPermissions(gateway: gateway);

    await permissions.ensureCallStartPermissions();

    expect(gateway.requestCalls, 0);
  });

  test('ensureCallStartPermissions honors stored choice and does not re-prompt (A2)',
      () async {
    final gateway = _FakeGateway(granted: false, requestGrants: false);
    final permissions = CallPermissions(gateway: gateway);

    // First prompt declines:
    await permissions.ensureCallStartPermissions();
    expect(gateway.requestCalls, 1);
    expect(await NotificationPermissionStore.getChoice(), 'denied');

    // Second call on relaunch:
    await permissions.ensureCallStartPermissions();
    expect(gateway.requestCalls, 1); // no second prompt
  });

  test('ensureBackgroundCallPermission reflects current status without '
      're-prompting', () async {
    final gateway = _FakeGateway(granted: false);
    final permissions = CallPermissions(gateway: gateway);

    expect(await permissions.ensureBackgroundCallPermission(), isFalse);
    expect(gateway.requestCalls, 0); // never re-asks

    gateway.granted = true; // e.g. the user granted it from Settings
    expect(await permissions.ensureBackgroundCallPermission(), isTrue);
  });

  test('openSettings delegates to the gateway', () async {
    final gateway = _FakeGateway();
    final permissions = CallPermissions(gateway: gateway);

    await permissions.openSettings();

    expect(gateway.settingsCalls, 1);
  });
}
