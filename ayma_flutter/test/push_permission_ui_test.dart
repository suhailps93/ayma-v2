import 'package:ayma_flutter/screens/notification_prefs_screen.dart';
import 'package:ayma_flutter/screens/push_primer_dialog.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/services/push_permission.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePerm extends PushPermission {
  _FakePerm(this.state);
  PushPermissionState state;
  int requests = 0;
  int settings = 0;

  @override
  Future<PushPermissionState> status() async => state;

  @override
  Future<PushPermissionState> request() async {
    requests++;
    return state = PushPermissionState.granted;
  }

  @override
  Future<bool> openSystemSettings() async {
    settings++;
    return true;
  }
}

class _FakeSvc extends NotificationService {
  _FakeSvc() : super(auth: MockFirebaseAuth());

  @override
  Future<Map<String, bool>> readPrefs() async => {};
}

Future<void> _pumpPrefs(WidgetTester t, _FakePerm p, List<int> synced) async {
  await t.pumpWidget(MaterialApp(
    home: NotificationPrefsScreen(
      service: _FakeSvc(),
      permission: p,
      onGranted: () async => synced.add(1),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _pumpPrimer(WidgetTester t, _FakePerm p, List<int> synced) async {
  await t.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () => showPushPrimer(ctx,
            permission: p, onGranted: () async => synced.add(1)),
        child: const Text('go'),
      ),
    ),
  ));
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('granted shows On, manage link, and syncs token', (t) async {
    final synced = <int>[];
    await _pumpPrefs(t, _FakePerm(PushPermissionState.granted), synced);
    expect(find.text('On'), findsOneWidget);
    expect(find.text('Manage in system settings'), findsOneWidget);
    expect(synced.length, 1);
  });

  testWidgets('not asked: Turn on requests, then syncs', (t) async {
    final synced = <int>[];
    final p = _FakePerm(PushPermissionState.notAsked);
    await _pumpPrefs(t, p, synced);
    await t.tap(find.text('Turn on'));
    await t.pumpAndSettle();
    expect(p.requests, 1);
    expect(p.settings, 0);
    expect(synced.length, 1);
    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('denied: button opens system settings, no request', (t) async {
    final p = _FakePerm(PushPermissionState.denied);
    await _pumpPrefs(t, p, []);
    await t.tap(find.text('Open settings'));
    await t.pumpAndSettle();
    expect(p.requests, 0);
    expect(p.settings, 1);
  });

  testWidgets('resume re-checks and syncs once granted', (t) async {
    final synced = <int>[];
    final p = _FakePerm(PushPermissionState.denied);
    await _pumpPrefs(t, p, synced);
    expect(synced, isEmpty);
    p.state = PushPermissionState.granted;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.text('On'), findsOneWidget);
    expect(synced.length, 1);
  });

  testWidgets('primer: Not now never triggers the OS prompt', (t) async {
    final p = _FakePerm(PushPermissionState.notAsked);
    await _pumpPrimer(t, p, []);
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(p.requests, 0);
  });

  testWidgets('primer: Turn on requests and syncs', (t) async {
    final synced = <int>[];
    final p = _FakePerm(PushPermissionState.notAsked);
    await _pumpPrimer(t, p, synced);
    await t.tap(find.text('Turn on notifications'));
    await t.pumpAndSettle();
    expect(p.requests, 1);
    expect(synced.length, 1);
  });

  testWidgets('primer: skipped when already decided', (t) async {
    final p = _FakePerm(PushPermissionState.denied);
    await _pumpPrimer(t, p, []);
    expect(find.text('Not now'), findsNothing);
  });

  testWidgets('primer: Not now TextButton clears the 44 touch floor '
      '(jobs defect 8)', (t) async {
    final p = _FakePerm(PushPermissionState.notAsked);
    await _pumpPrimer(t, p, []);

    final size = t.getSize(
      find.ancestor(
        of: find.text('Not now'),
        matching: find.byType(TextButton),
      ),
    );
    // Job floor is 44; M3 pads the tap target to 48.
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.height, 48);
  });
}
