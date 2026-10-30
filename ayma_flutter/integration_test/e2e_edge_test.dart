// Corner-case E2E scenarios driven against the seeded `demo-edge-*` accounts
// (see scripts/seed_demo_edge_accounts.py). Signed in as Daniel (test1, a man
// seeking women), these cover matching/explore edges the three complete demo
// accounts can't express:
//
//   GATES   — Explore excludes the hard-dealbreaker accounts (age-over,
//             one-sided orientation, out-of-radius location) and includes the
//             valid ones (0-photo, age-at-floor, mutual).
//   NOPHOTO — a 0-photo but otherwise-valid profile appears in Explore and its
//             report opens (distinct from the practice-persona exclusion).
//   ZERO    — a hard-dealbreaker pair's report scores 0%.
//   MATCH   — a mutual-like pair's report AppBar reads "Match" (vs the
//             non-mutual "Compatibility" the Sofia suite covers).
//
// Run: flutter test integration_test/e2e_edge_test.dart -d emulator-5554
// (or via tool/run_e2e.sh, which also captures screenshots + the report).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;
import 'package:ayma_flutter/routing/app_router.dart' show appRouter;

import 'helpers.dart';

// Daniel's uid (persona demo-test1), the logged-in viewer for these edges.
const danielEmailUid = 'demo-test1';

// Seeded corner-case accounts (scripts/seed_demo_edge_accounts.py).
// Only the uids we open reports for are needed; the rest are checked by name.
const _nophoto = 'demo-edge-nophoto';
const _ageover = 'demo-edge-ageover';
const _mutual = 'demo-edge-mutual';

const _nophotoName = 'Nadia';
const _ageminName = 'Mara';
const _ageoverName = 'Teresa';
const _orientName = 'Robin';
const _locoutName = 'Elena';
const _mutualName = 'Hana';

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

  testWidgets('corner cases GATES/NOPHOTO/ZERO/MATCH (Daniel + demo-edge-*)',
      (tester) async {
    await presignIn(danielEmail);
    await bootApp(tester, app.main);
    final landed = await awaitShell(tester);
    await dismissTour(tester);
    if (!landed) {
      fail('GATES', 'did not reach signed-in main shell');
      _print(results);
      await settleHarness(tester);
      expect(landed, isTrue, reason: 'login failed; cannot run corner cases');
      return;
    }

    // ---- GATES + NOPHOTO: the Explore roster for Daniel ----
    // Product correction (founder, 2026-10-29): Explore now SHOWS everyone,
    // including hard-dealbreaker profiles — the score enforces the dealbreaker
    // (0% + reasons), it is no longer hidden from the feed. So every seeded
    // edge account (valid AND dealbreaker) must appear; only practice personas
    // stay excluded (covered by the Sofia suite's E / "Maya"). Removing the
    // Explore gate makes the feed longer, so collect names across the full
    // scroll (the GridView only builds visible cards).
    await openExplore(tester);
    await pumpUntil(tester, find.textContaining(_nophotoName),
        timeout: const Duration(seconds: 75));
    final targets = [
      _nophotoName, _ageminName, _mutualName, // valid
      _ageoverName, _orientName, _locoutName, // dealbreakers (now shown)
    ];
    final seenNames = await _collectNamesWhileScrolling(tester, targets);
    final roster = {for (final n in targets) n: seenNames.contains(n)};
    await shot(tester, 'GATES');
    if (roster.values.every((v) => v)) {
      pass('GATES',
          'Explore shows all profiles incl. hard-dealbreaker ones (score '
          'enforces the gate, not hiding): $roster');
    } else {
      fail('GATES',
          'Explore roster incomplete: $roster (want all true — dealbreaker '
          'profiles must SHOW in Explore)');
    }

    if (roster[_nophotoName]!) {
      // 0-photo card present; confirm its report opens (profile with no images).
      final opened = await _openReportForUid(tester, _nophoto);
      final notZero = !find.text('0%').evaluate().isNotEmpty;
      await shot(tester, 'NOPHOTO');
      if (opened && notZero) {
        pass('NOPHOTO',
            '0-photo profile appears in Explore and its report opens with a '
            'non-zero score');
      } else {
        fail('NOPHOTO',
            'reportOpened=$opened, nonZeroScore=$notZero (want both true)');
      }
      appRouter.go('/');
      await pumpUntil(tester, find.byIcon(Icons.search_rounded),
          timeout: const Duration(seconds: 20));
    } else {
      fail('NOPHOTO', '0-photo account "$_nophotoName" not in Explore');
    }

    // ---- ZERO: hard-dealbreaker pair report scores 0% + lists why ----
    final zeroOpened = await _openReportForUid(tester, _ageover);
    final zeroShown = find.text('0%').evaluate().isNotEmpty;
    // New behaviour (fix/dealbreakers-show-not-hide): the 0% report explains
    // itself — a "Why this is 0%" section listing each dealbreaker reason.
    // Accept any of the expected phrasings.
    final reasons = const ['Why this is 0%', 'dealbreaker', 'Dealbreaker', 'Deal-breaker']
        .any((t) => find.textContaining(t).evaluate().isNotEmpty);
    await shot(tester, 'ZERO');
    if (zeroOpened && zeroShown && reasons) {
      pass('ZERO',
          'hard-dealbreaker report shows 0% and lists the dealbreaker reason(s)');
    } else {
      fail('ZERO',
          'reportOpened=$zeroOpened, "0%"=$zeroShown, reasonsListed=$reasons '
          '(want all true; reasons pending fix/dealbreakers-show-not-hide)');
    }
    appRouter.go('/');
    await pumpUntil(tester, find.byIcon(Icons.search_rounded),
        timeout: const Duration(seconds: 20));

    // ---- MATCH: mutual-like pair report AppBar reads "Match" ----
    final matchOpened = await _openReportForUid(tester, _mutual);
    final isMatch = find.text('Match').evaluate().isNotEmpty;
    final isCompat = find.text('Compatibility').evaluate().isNotEmpty;
    await shot(tester, 'MATCH');
    if (matchOpened && isMatch && !isCompat) {
      pass('MATCH',
          'mutual-like pair report AppBar reads "Match" (not "Compatibility")');
    } else {
      fail('MATCH',
          'reportOpened=$matchOpened, Match=$isMatch, Compatibility=$isCompat '
          '(want Match=true, Compatibility=false)');
    }

    await settleHarness(tester);
    _print(results);
    final failures = results.entries.where((e) => e.value.startsWith('FAIL'));
    expect(failures, isEmpty,
        reason: 'corner cases failed:\n'
            '${failures.map((e) => "${e.key}: ${e.value}").join("\n")}');
  }, timeout: const Timeout(Duration(minutes: 12)));
}

/// Deterministic match-doc id for an unordered pair (mirrors the backend's
/// `pair_key.sorted_pair_key`: sorted uids joined by `__`).
String _matchId(String a, String b) {
  final s = [a, b]..sort();
  return '${s[0]}__${s[1]}';
}

/// Opens a subject's report DIRECTLY via `/match/{id}` (GET only — no
/// public-profile checkCompatibility, which would recompute and could reset the
/// mutual-like status). Waits for the AppBar title and the body to stream in.
Future<bool> _openReportForUid(WidgetTester tester, String uid) async {
  appRouter.push('/match/${_matchId(danielEmailUid, uid)}');
  final end = DateTime.now().add(const Duration(seconds: 75));
  while (DateTime.now().isBefore(end)) {
    await pumpFor(tester, const Duration(milliseconds: 300));
    if (find.text('Compatibility').evaluate().isNotEmpty ||
        find.text('Match').evaluate().isNotEmpty) {
      // Let the score block / breakdown stream in.
      await pumpFor(tester, const Duration(seconds: 6));
      return true;
    }
  }
  return false;
}

/// Scrolls the Explore grid top-to-bottom, collecting which of [targets] become
/// visible at any point (the GridView only builds on-screen cards, so a name
/// near the bottom of a long feed is only findable mid-scroll). Returns the set
/// of target names seen.
Future<Set<String>> _collectNamesWhileScrolling(
  WidgetTester tester,
  List<String> targets,
) async {
  final found = <String>{};
  void sweep() {
    for (final n in targets) {
      if (find.textContaining(n).evaluate().isNotEmpty) found.add(n);
    }
  }

  sweep();
  final grid = find.byType(GridView);
  if (grid.evaluate().isNotEmpty) {
    for (var i = 0; i < 18 && found.length < targets.length; i++) {
      await tester.drag(grid.first, const Offset(0, -320));
      await pumpFor(tester, const Duration(milliseconds: 450));
      sweep();
    }
  }
  return found;
}

void _print(Map<String, String> results) {
  debugPrint('\n============ EDGE E2E PASS/FAIL ============');
  for (final k in ['GATES', 'NOPHOTO', 'ZERO', 'MATCH']) {
    debugPrint('  $k: ${results[k] ?? "NOT RUN"}');
  }
  debugPrint('============================================\n');
}
