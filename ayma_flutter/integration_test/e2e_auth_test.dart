// Signed-out auth / welcome-flow E2E scenario. Boots with no FirebaseAuth
// session so the router lands on the sign-in screen (the pre-sign-in "welcome"
// surface), and asserts the auth entry points are present.
//
// Run: flutter test integration_test/e2e_auth_test.dart -d emulator-5554
// (or via tool/run_e2e.sh, which revokes mic so the sign-in welcome-voice
// session can't connect, and captures the screenshot).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;

import 'helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final results = <String, String>{};
  void pass(String k, String d) {
    results[k] = 'PASS — $d';
    emit('E2E_RESULT $k PASS $d');
  }

  void fail(String k, String d) {
    results[k] = 'FAIL — $d';
    emit('E2E_RESULT $k FAIL $d');
  }

  testWidgets('signed-out boot lands on the sign-in / welcome screen (AUTH)',
      (tester) async {
    await signOutForTest();
    await bootApp(tester, app.main);

    // The router redirects a signed-out user to the sign-in screen. Wait for a
    // sign-in affordance (the consent checkbox or the "Email" option).
    final terms = find.byKey(const Key('signin_terms_checkbox'));
    final onSignIn = await pumpUntil(tester, terms,
        timeout: const Duration(seconds: 60));

    final emailOption =
        find.widgetWithText(OutlinedButton, 'Email').evaluate().isNotEmpty ||
            find.text('Email').evaluate().isNotEmpty;
    final biometric =
        find.byKey(const Key('signin_biometric_checkbox')).evaluate().isNotEmpty;
    final signUp = find.textContaining('Sign up').evaluate().isNotEmpty;
    await shot(tester, 'AUTH');

    if (onSignIn && emailOption && biometric) {
      pass('AUTH',
          'signed-out boot shows the sign-in screen: Email option, terms + '
          'biometric consent checkboxes${signUp ? ", sign-up toggle" : ""}');
    } else {
      fail('AUTH',
          'sign-in UI incomplete: termsCheckbox=$onSignIn, emailOption='
          '$emailOption, biometricCheckbox=$biometric '
          '(want all true)');
    }

    await settleHarness(tester);
    final failures = results.entries.where((e) => e.value.startsWith('FAIL'));
    expect(failures, isEmpty,
        reason: failures.map((e) => '${e.key}: ${e.value}').join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
