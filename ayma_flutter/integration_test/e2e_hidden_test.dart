// Fixture-hiding E2E scenario, from a NORMAL (non-bypass) viewer.
//
// The demo-edge-* test fixtures are flagged `exclude_from_explore` and hidden
// from real users' Explore (functions/bootstrap/explore.py). Hiding is bypassed
// only for viewers whose uid is in `explore_fixture_bypass_uids`
// (default demo-test1/2/3) — see docs/TESTING_E2E.md. This suite signs in as
// `demo-edge-viewer` (NOT in that set, seeded by scripts/seed_demo_edge_accounts.py)
// and asserts its Explore HIDES every demo-edge-* fixture while still SHOWING
// the curated demo set (demo-test1/2/3 = Daniel/Sofia/Priya).
//
// Run: flutter test integration_test/e2e_hidden_test.dart -d emulator-5554
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;

import 'helpers.dart';

const _viewerEmail = 'demo-edge-viewer@gmail.com';

// Curated demo accounts that MUST stay visible to everyone.
const _curated = ['Daniel', 'Sofia', 'Priya'];
// Test fixtures that MUST be hidden from a non-bypass viewer.
const _fixtures = ['Nadia', 'Mara', 'Teresa', 'Robin', 'Elena', 'Hana'];

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

  testWidgets('non-bypass viewer: demo-edge-* hidden, demo-test1/2/3 shown (HIDDEN)',
      (tester) async {
    final authed = await presignIn(_viewerEmail);
    await bootApp(tester, app.main);
    final landed = await awaitShell(tester);
    await dismissTour(tester);
    if (!authed || !landed) {
      fail('HIDDEN',
          'could not sign in / reach the shell as the non-bypass viewer '
          '(authed=$authed, shell=$landed)');
      await settleHarness(tester);
      expect(results['HIDDEN']!.startsWith('PASS'), isTrue,
          reason: results['HIDDEN']);
      return;
    }

    await openExplore(tester);
    // Wait for the feed to populate (a curated account should appear).
    await pumpUntil(tester, find.textContaining('Sofia'),
        timeout: const Duration(seconds: 75));
    final seen = await _sweepNames(tester, [..._curated, ..._fixtures]);
    await shot(tester, 'HIDDEN');

    final curatedShown = {for (final n in _curated) n: seen.contains(n)};
    final fixturesShown = {for (final n in _fixtures) n: seen.contains(n)};
    final allCurated = curatedShown.values.every((v) => v);
    final noFixtures = fixturesShown.values.every((v) => !v);
    if (allCurated && noFixtures) {
      pass('HIDDEN',
          'non-bypass viewer sees curated demo accounts $curatedShown and no '
          'demo-edge-* fixtures $fixturesShown');
    } else {
      fail('HIDDEN',
          'curated=$curatedShown (want all true), fixtures=$fixturesShown '
          '(want all false)');
    }

    await settleHarness(tester);
    final failures = results.entries.where((e) => e.value.startsWith('FAIL'));
    expect(failures, isEmpty,
        reason: failures.map((e) => '${e.key}: ${e.value}').join('\n'));
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// Scrolls the Explore grid top-to-bottom collecting which [names] appear.
Future<Set<String>> _sweepNames(WidgetTester tester, List<String> names) async {
  final found = <String>{};
  void sweep() {
    for (final n in names) {
      if (find.textContaining(n).evaluate().isNotEmpty) found.add(n);
    }
  }

  sweep();
  final grid = find.byType(GridView);
  if (grid.evaluate().isNotEmpty) {
    for (var i = 0; i < 30 && found.length < names.length; i++) {
      await tester.drag(grid.first, const Offset(0, -220));
      await pumpFor(tester, const Duration(milliseconds: 450));
      sweep();
    }
  }
  return found;
}
