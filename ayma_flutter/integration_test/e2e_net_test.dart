// Offline + recovery E2E scenario, driven host-side (no app seam).
//
// The test prints `E2E_NET off` / `E2E_NET on` markers; tool/run_e2e.sh tails
// the log and toggles the device radios with `adb shell svc wifi/data`. With
// the network down during boot the splash can't reach /bootstrap and shows its
// "Couldn't connect" + Retry state; re-enabling the network and tapping Retry
// must recover to the signed-in shell.
//
// Only meaningful under tool/run_e2e.sh (which sets --dart-define=E2E_NET=true
// and performs the toggles). Under a plain `flutter test` the network stays up,
// so the scenarios self-skip to keep the file green standalone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;

import 'helpers.dart';

const bool _netControl = bool.fromEnvironment('E2E_NET');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final results = <String, String>{};
  void pass(String k, String d) {
    results[k] = 'PASS — $d';
    debugPrint('E2E_RESULT $k PASS $d');
  }

  void fail(String k, String d) {
    results[k] = 'FAIL — $d';
    debugPrint('E2E_RESULT $k FAIL $d');
  }

  testWidgets('offline splash + recovery (OFFLINE / RECOVER)', (tester) async {
    // Authenticate while the network is still up, so the signed-in splash is
    // what hits the offline /bootstrap.
    await presignIn(sofiaEmail);

    if (!_netControl) {
      // No host toggler attached: boot online and self-skip the net scenarios.
      await bootApp(tester, app.main);
      await awaitShell(tester);
      pass('OFFLINE', 'skipped — run via tool/run_e2e.sh for the adb toggle');
      pass('RECOVER', 'skipped — run via tool/run_e2e.sh for the adb toggle');
      await settleHarness(tester);
      return;
    }

    // Ask the host to take the device offline, then boot into the splash.
    debugPrint('E2E_NET off');
    await pumpFor(tester, const Duration(seconds: 4)); // host disables radios
    await bootApp(tester, app.main);

    final offline = await pumpUntil(
      tester,
      find.textContaining("Couldn't connect"),
      timeout: const Duration(seconds: 60),
    );
    await shot(tester, 'OFFLINE');
    if (offline) {
      pass('OFFLINE',
          'splash shows "Couldn\'t connect" + Retry while the device is offline');
    } else {
      fail('OFFLINE',
          'no "Couldn\'t connect" splash state appeared within 60s offline');
    }

    // Restore the network and recover via Retry.
    debugPrint('E2E_NET on');
    await pumpFor(tester, const Duration(seconds: 6)); // host re-enables radios
    final retry = find.widgetWithText(TextButton, 'Retry');
    if (retry.evaluate().isNotEmpty) {
      await tester.tap(retry.first, warnIfMissed: false);
    }
    final recovered = await pumpUntil(
      tester,
      find.byIcon(Icons.search_rounded),
      timeout: const Duration(seconds: 90),
    );
    await shot(tester, 'RECOVER');
    if (recovered) {
      pass('RECOVER',
          'network restored + Retry recovers to the signed-in shell');
    } else {
      fail('RECOVER', 'did not reach the shell after restoring the network');
    }

    await settleHarness(tester);
    final failures = results.entries.where((e) => e.value.startsWith('FAIL'));
    expect(failures, isEmpty,
        reason: failures.map((e) => '${e.key}: ${e.value}').join('\n'));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
