// DM GIF feature (§6.6) E2E scenario. A seeded GIF message
// (scripts/seed_demo_edge_accounts.py, Daniel↔Sofia thread) must render as an
// inline animated-gif bubble (Image.network of the attachment url) in the DM
// thread — the real send path stores the same 'gif'-type message.
//
// Run: flutter test integration_test/e2e_dm_gif_test.dart -d emulator-5554
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;
import 'package:ayma_flutter/routing/app_router.dart' show appRouter;

import 'helpers.dart';

// Daniel↔Sofia DM thread (sorted-pair id). Sofia opens it and sees the gif.
const _threadId = 'demo-test1__demo-test2';

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

  testWidgets('DM GIF renders as an inline gif bubble (GIF)', (tester) async {
    await presignIn(sofiaEmail);
    await bootApp(tester, app.main);
    final landed = await awaitShell(tester);
    await dismissTour(tester);
    if (!landed) {
      fail('GIF', 'did not reach the signed-in shell');
      await settleHarness(tester);
      expect(landed, isTrue, reason: 'login failed');
      return;
    }

    appRouter.push('/dm/$_threadId');
    // The thread streams its messages in; wait for the seeded gif's Image.network
    // bubble (its url carries the giphy marker, distinct from avatar photos).
    bool gifBubble() => find
        .byWidgetPredicate((w) =>
            w is Image &&
            w.image is NetworkImage &&
            (w.image as NetworkImage).url.contains('giphy'))
        .evaluate()
        .isNotEmpty;

    final end = DateTime.now().add(const Duration(seconds: 40));
    var found = false;
    while (DateTime.now().isBefore(end) && !found) {
      await pumpFor(tester, const Duration(milliseconds: 400));
      found = gifBubble();
    }
    await shot(tester, 'GIF');
    if (found) {
      pass('GIF',
          'a GIF message renders as an inline Image.network gif bubble in the '
          'DM thread');
    } else {
      fail('GIF',
          'no inline gif bubble (Image.network with the gif url) in the thread '
          '(texts=${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((d) => d.trim().isNotEmpty).take(12).toList()})');
    }

    await settleHarness(tester);
    final failures = results.entries.where((e) => e.value.startsWith('FAIL'));
    expect(failures, isEmpty,
        reason: failures.map((e) => '${e.key}: ${e.value}').join('\n'));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
