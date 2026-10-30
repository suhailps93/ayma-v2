// End-to-end regression harness for the 8 behaviours shipped in build 2237.
//
// Runs the REAL app against the LIVE backend on a device/emulator:
//   flutter test integration_test/e2e_behaviors_test.dart -d emulator-5554
//
// The app is booted ONCE (calling app.main() twice re-inits Firebase and
// throws), signed in as Sofia (test2), and each behaviour is checked in
// sequence. Every check records a PASS/FAIL line into [results] instead of
// hard-failing, so one failure never hides the rest; the full table is printed
// at the end and the test then asserts every behaviour passed (so the harness
// is red whenever a real 2237 bug is present, with the table above explaining
// which).
//
// Why Sofia (test2): logged in as Sofia (woman seeking men) the demo data lets
// one session exercise the most behaviours deterministically —
//   * Explore must INCLUDE Daniel (a man, valid orientation) and EXCLUDE Priya
//     (a woman — orientation-gated) and any practice persona (bug B / E);
//   * opening Daniel's report yields the strong Daniel×Sofia compatibility read
//     (full dimension breakdown, taste 68, shared folk/indie entities) for
//     bugs H / D / G / F.
// Bug C (web-research empty state) is reached by routing to a never-researched
// subject. Branches the seed data cannot produce (a genuine mutual "Match"
// title, a hard-dealbreaker 0% report) are documented in the final report and
// covered by the in-tree widget/unit tests, not here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;
import 'package:ayma_flutter/routing/app_router.dart' show appRouter;
import 'package:ayma_flutter/widgets/ayma_photo.dart' show AymaPhoto;
import 'package:ayma_flutter/widgets/ayma_rail_icons.dart' show AymaMatchGlyph;
import 'package:ayma_flutter/widgets/share_report_sheet.dart'
    show RecipientPicker;

import 'helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // behaviour letter -> result line. Each result is ALSO flushed to stdout the
  // instant it resolves as `E2E_RESULT <letter> PASS|FAIL <detail>`, so a tail
  // of the run streams verdicts live instead of only at the end.
  final results = <String, String>{};
  void pass(String key, String detail) {
    results[key] = 'PASS — $detail';
    emit('E2E_RESULT $key PASS $detail');
  }

  void fail(String key, String detail) {
    results[key] = 'FAIL — $detail';
    emit('E2E_RESULT $key FAIL $detail');
  }

  testWidgets('2237 behaviours B/E/H/D/P/C/F/G end-to-end (Sofia)',
      (tester) async {
    await presignIn(sofiaEmail);
    await bootApp(tester, app.main);
    final landed = await awaitShell(tester);
    await dismissTour(tester);
    if (!landed) {
      fail('LOGIN', 'did not reach signed-in main shell after login');
      _printTable(results);
      await settleHarness(tester);
      failNow('login failed; cannot run behaviours');
    }

    // ---- Explore: bug B (candidate shows) + bug E (practice persona hidden) ----
    final onExplore = await openExplore(tester);
    if (!onExplore) {
      fail('B', 'Explore screen never loaded');
      fail('E', 'Explore screen never loaded');
    } else {
      // The live feed is scored server-side and can take ~45s on a cold backend.
      // Per the 2239 product rule Explore SHOWS everyone (dealbreakers surface as
      // a 0% report, not hidden), so B now just checks a real candidate (Daniel)
      // appears; the exclusion cases are covered by the edge suite (GATES/ZERO)
      // and HIDDEN. Practice personas (E) are still filtered out. The feed is
      // long now, so sweep names across the full scroll.
      await pumpUntil(tester, find.byType(GridView),
          timeout: const Duration(seconds: 75));
      final seen = await _sweepExploreNames(tester, ['Daniel', 'Maya']);
      await shot(tester, 'B');
      await shot(tester, 'E');

      if (seen.contains('Daniel')) {
        pass('B', 'Explore (as Sofia) shows a real candidate (Daniel)');
      } else {
        fail('B', 'Explore (as Sofia) did not show Daniel across the feed');
      }
      if (!seen.contains('Maya')) {
        pass('E', 'practice persona "Maya" absent from Explore');
      } else {
        fail('E', 'practice persona "Maya" appeared in Explore feed');
      }
    }

    // ---- Open Daniel's compatibility report (for H / D / G / F) ----
    final reportOpen = await _openDanielReport(tester);
    if (!reportOpen) {
      for (final k in ['H', 'D', 'G', 'F']) {
        fail(k, 'could not open Daniel×Sofia compatibility report');
      }
    } else {
      // The dimension breakdown streams in after the AppBar title; wait for the
      // per-dimension stat blocks specifically (the taste card can appear first
      // in a loading state, so don't break on it).
      final bodyEnd = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(bodyEnd)) {
        await pumpFor(tester, const Duration(milliseconds: 500));
        if (_dimensionBlockKeys().length >= 3) break;
      }
      debugPrint('REPORT: body loaded -> dims=${_dimensionBlockKeys()} '
          'tasteCard=${find.byKey(const Key('tasteMatchCard')).evaluate().isNotEmpty} '
          'texts=${_visibleTexts().take(30).toList()}');
      await shot(tester, 'D'); // report title + top of breakdown
      await shot(tester, 'H'); // dimension breakdown in view

      // Bug D: a non-mutual pair reads "Compatibility" (seed status == scored,
      // not mutual_interest).
      final isCompat = find.text('Compatibility').evaluate().isNotEmpty;
      final isMatch = find.text('Match').evaluate().isNotEmpty;
      if (isCompat && !isMatch) {
        pass('D', 'non-mutual report AppBar reads "Compatibility" (not "Match")');
      } else {
        fail('D',
            'report title: Compatibility=$isCompat Match=$isMatch '
            '(want Compatibility=true, Match=false)');
      }

      // Bug H: FULL dimension breakdown, not a score-only lite doc. Count the
      // per-dimension stat blocks (ValueKey 'livingReportBlock:dim:<key>').
      final dimKeys = _dimensionBlockKeys();
      final labelsFound = <String>[];
      for (final concept in const [
        'Life goals',
        'Personality',
        'Lifestyle',
        'Communication',
        'Shared interests',
      ]) {
        if (find.textContaining(concept).evaluate().isNotEmpty) {
          labelsFound.add(concept);
        }
      }
      if (dimKeys.length >= 5 || labelsFound.length >= 5) {
        pass('H',
            'full breakdown: ${dimKeys.length} dimension blocks; '
            'labels matched: ${labelsFound.join(", ")}');
      } else {
        fail('H',
            'lite/partial report: only ${dimKeys.length} dimension blocks '
            '(keys=$dimKeys); concept labels found=${labelsFound.join(", ")} '
            '(want >=5 of Life goals/Personality/Lifestyle/Communication/'
            'Shared interests)');
      }

      // Bug G: taste card grounded in both-stated domains. It is the LAST item
      // of the report's lazy ListView, so scroll it into view to build it, then
      // wait for it to resolve past its "Comparing your tastes…" loading state.
      final tasteCard = find.byKey(const Key('tasteMatchCard'));
      await _scrollReportTo(tester, tasteCard);
      await pumpUntil(tester, find.text('You both listed'),
          timeout: const Duration(seconds: 25));
      await shot(tester, 'G'); // taste card
      if (tasteCard.evaluate().isEmpty) {
        fail('G', 'taste card (key tasteMatchCard) not rendered in report '
            '(scrolled to bottom; r.taste likely null)');
      } else {
        final bothListed = find.text('You both listed').evaluate().isNotEmpty;
        final sharedChips =
            find.byKey(const Key('tasteMatchShared')).evaluate().isNotEmpty;
        // A stated-by-both entity should appear as a shared chip (not an
        // inferred Qloo prediction). Daniel×Sofia share folk/indie entities.
        final knownShared = const [
          'Bon Iver',
          'Fleet Foxes',
          'Lost in Translation',
          'Tartine',
          'Fleabag',
          'The Bear',
        ].where((e) => find.textContaining(e).evaluate().isNotEmpty).toList();
        if (bothListed && sharedChips) {
          pass('G',
              '"You both listed" section present'
              '${knownShared.isNotEmpty ? " with both-stated entities $knownShared" : ""}');
        } else {
          fail('G',
              'taste card present but "You both listed"=$bothListed, '
              'sharedChips=$sharedChips (want both true); '
              'knownSharedEntities=$knownShared');
        }
      }

      // ---- Bug P: Instagram-DM-style "Send to a user" picker ----
      // Run on the stable first-opened report (before F's recompute/reopen).
      // Open the report's Share action -> "Send to a user" -> RecipientPicker.
      final shareBtn = find.byTooltip('Share');
      if (shareBtn.evaluate().isEmpty) {
        fail('P', 'Share action not found in the report AppBar');
      } else {
        await tester.tap(shareBtn.first, warnIfMissed: false);
        final sendTile = find.text('Send to a user');
        if (!await pumpUntil(tester, sendTile,
            timeout: const Duration(seconds: 10))) {
          fail('P', 'share sheet "Send to a user" option not shown');
        } else {
          await tester.tap(sendTile.first, warnIfMissed: false);
          final picker = find.byType(RecipientPicker);
          final haveSearch = await pumpUntil(
              tester, find.byKey(const ValueKey('recipientSearch')),
              timeout: const Duration(seconds: 15));
          // Let the picker load its recipients (DM threads + matches).
          await pumpUntil(tester, find.widgetWithText(TextButton, 'Send'),
              timeout: const Duration(seconds: 20));
          final searchHint =
              find.widgetWithText(TextField, 'Search people').evaluate().isNotEmpty;
          final perRowSend =
              find.widgetWithText(TextButton, 'Send').evaluate().length;
          final avatars = find.descendant(
            of: find.byType(RecipientPicker),
            matching: find.byType(AymaPhoto),
          ).evaluate().length;
          final matchedFirst = find.text('Matched').evaluate().isNotEmpty;
          final pickerShown = picker.evaluate().isNotEmpty;
          debugPrint('REPORT: picker shown=$pickerShown search=$haveSearch '
              'searchHint=$searchHint sendButtons=$perRowSend avatars=$avatars '
              'matchedLabel=$matchedFirst texts=${_visibleTexts().take(20).toList()}');
          await shot(tester, 'P'); // recipient picker
          if (pickerShown && haveSearch && searchHint && perRowSend >= 1) {
            pass('P',
                'picker shows search ("Search people"), $perRowSend per-row Send '
                'button(s), $avatars photo avatar(s)'
                '${matchedFirst ? ", matched users labelled/first" : ""}');
          } else {
            fail('P',
                'picker=$pickerShown, searchField=$haveSearch, '
                'searchHint=$searchHint, perRowSend=$perRowSend, avatars=$avatars '
                '(want picker+search+hint+>=1 Send)');
          }
          // Close the two bottom sheets before the next behaviour.
          appRouter.pop();
          await pumpFor(tester, const Duration(milliseconds: 400));
          if (find.text('Send to a user').evaluate().isNotEmpty) {
            appRouter.pop();
            await pumpFor(tester, const Duration(milliseconds: 400));
          }
        }
      }

      // Bug F: Recalculate forces a recompute + cache makes re-open fast.
      // The Recalculate action lives in the fixed AppBar (always reachable).
      final haveRecalc = find.byTooltip('Recalculate').evaluate().isNotEmpty;
      var recomputing = false;
      if (haveRecalc) {
        await tester.tap(find.byTooltip('Recalculate').first,
            warnIfMissed: false);
        recomputing = await pumpUntil(
            tester, find.textContaining('Recalculating'),
            timeout: const Duration(seconds: 20));
        await shot(tester, 'F'); // recompute banner
      }

      // Cache / instant re-open: pop back to the profile and re-open the report
      // via the match glyph. A scored pair's checkCompatibility returns the
      // cached report, and MatchReportCache paints the body without the loading
      // orb. Measure glyph-tap -> body paint.
      var bodyMs = -1;
      appRouter.pop();
      final backOnProfile = await pumpUntil(
          tester, find.byType(AymaMatchGlyph),
          timeout: const Duration(seconds: 20));
      if (backOnProfile) {
        final t0 = DateTime.now();
        final reopened = await _openReportFromProfile(tester);
        if (reopened) {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (DateTime.now().isBefore(deadline)) {
            await pumpFor(tester, const Duration(milliseconds: 100));
            if (_dimensionBlockKeys().isNotEmpty) {
              bodyMs = DateTime.now().difference(t0).inMilliseconds;
              break;
            }
          }
        }
      }

      if (recomputing) {
        pass('F',
            'Recalculate forces a recompute ("Recalculating this report…"); '
            'cached re-open painted the breakdown in '
            '${bodyMs >= 0 ? "${bodyMs}ms" : "n/a"}');
      } else {
        fail('F',
            'Recalculate present=$haveRecalc, recompute banner shown=$recomputing '
            '(want true); cached re-open body=${bodyMs}ms');
      }
    }

    // ---- Bug C: web-research never-run empty state ----
    appRouter.push('/deep-dive/name_a-subject-never-researched-zzq');
    final emptyState = await pumpUntil(
      tester,
      find.text('No web research yet'),
      timeout: const Duration(seconds: 40),
    );
    final runReport =
        find.widgetWithText(FilledButton, 'Run web search').evaluate().isNotEmpty;
    final errorShown =
        find.textContaining("Couldn't load").evaluate().isNotEmpty;
    await shot(tester, 'C'); // web-research empty state
    if (emptyState && runReport && !errorShown) {
      pass('C',
          '"No web research yet" + "Run web search" shown for never-run subject '
          '(no "Couldn\'t load" error)');
    } else {
      fail('C',
          'emptyState=$emptyState, runReport=$runReport, errorShown=$errorShown '
          '(want emptyState=true, runReport=true, errorShown=false)');
    }

    await settleHarness(tester);
    _printTable(results);

    // Make the harness red if any behaviour regressed; the table above has the
    // detail for each.
    final failures = results.entries.where((e) => e.value.startsWith('FAIL'));
    expect(failures, isEmpty,
        reason: 'behaviours failed:\n${failures.map((e) => "${e.key}: ${e.value}").join("\n")}');
  }, timeout: const Timeout(Duration(minutes: 14)));
}

// ---------------------------------------------------------------------------
// Navigation / inspection helpers specific to this suite.
// ---------------------------------------------------------------------------

/// Scrolls the Explore grid top-to-bottom collecting which of [names] appear
/// (the feed is long now that Explore shows everyone; the GridView only builds
/// visible cards). Leaves the grid scrolled back near the top.
Future<Set<String>> _sweepExploreNames(
    WidgetTester tester, List<String> names) async {
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
      await pumpFor(tester, const Duration(milliseconds: 420));
      sweep();
    }
  }
  return found;
}

/// Scrolls the Explore grid until [target] is built + visible; returns whether
/// it was reached. Drags downward (content up) in steps.
Future<bool> _scrollToCard(WidgetTester tester, Finder target) async {
  if (target.evaluate().isNotEmpty) return true;
  final grid = find.byType(GridView);
  if (grid.evaluate().isEmpty) return target.evaluate().isNotEmpty;
  for (var i = 0; i < 34 && target.evaluate().isEmpty; i++) {
    await tester.drag(grid.first, const Offset(0, -220));
    await pumpFor(tester, const Duration(milliseconds: 420));
  }
  return target.evaluate().isNotEmpty;
}

/// Explore -> scroll to Daniel -> tap card -> public profile -> match glyph ->
/// report. Retries the tap (the OS notification dialog can race a tap).
Future<bool> _openDanielReport(WidgetTester tester) async {
  var haveGlyph = false;
  for (var attempt = 0; attempt < 3 && !haveGlyph; attempt++) {
    await dismissTour(tester);
    await openExplore(tester);
    final daniel = find.textContaining('Daniel Reyes');
    if (!await _scrollToCard(tester, daniel)) {
      debugPrint('REPORT: Daniel card not reached (attempt $attempt)');
      continue;
    }
    try {
      await tester.ensureVisible(daniel.first);
      await tester.pump(const Duration(milliseconds: 300));
    } catch (_) {/* already visible */}
    final tappable = find.ancestor(
      of: daniel.first,
      matching: find.byWidgetPredicate(
          (w) => w is GestureDetector && w.onTap != null),
    );
    await tester.tap(
        tappable.evaluate().isNotEmpty ? tappable.first : daniel.first,
        warnIfMissed: false);
    haveGlyph = await pumpUntil(tester, find.byType(AymaMatchGlyph),
        timeout: const Duration(seconds: 25));
    debugPrint('REPORT: tap Daniel attempt $attempt -> glyph=$haveGlyph '
        'texts=${_visibleTexts().take(10).toList()}');
  }
  if (!haveGlyph) return false;
  return _openReportFromProfile(tester);
}

/// On a public profile, tap the match glyph and wait for the report AppBar.
Future<bool> _openReportFromProfile(WidgetTester tester) async {
  await dismissTour(tester);
  final glyph = find.byType(AymaMatchGlyph);
  if (glyph.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(glyph.first);
    await tester.pump(const Duration(milliseconds: 200));
  } catch (_) {/* already visible */}
  await tester.tap(glyph.first, warnIfMissed: false);
  // checkCompatibility round-trips, then pushes /match/<id>.
  final opened = await pumpUntil(tester, find.text('Compatibility'),
      timeout: const Duration(seconds: 75));
  debugPrint('REPORT: after glyph tap -> compatibilityTitle=$opened, '
      'texts=${_visibleTexts().take(14).toList()}');
  return opened;
}

List<String> _visibleTexts() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data)
    .whereType<String>()
    .where((d) => d.trim().isNotEmpty)
    .toList();

/// Scrolls the report's scrollable until [target] is built and visible. The
/// match report is long (7 dimensions with rationale + evidence), so the taste
/// card at its end needs many scrolls; drag downward (negative dy) to advance.
Future<void> _scrollReportTo(WidgetTester tester, Finder target) async {
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
    await tester.drag(scrollable.first, const Offset(0, -500));
    await pumpFor(tester, const Duration(milliseconds: 300));
  }
  if (target.evaluate().isNotEmpty) {
    try {
      await tester.ensureVisible(target.first);
    } catch (_) {/* best effort */}
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Keys of per-dimension stat blocks currently in the tree
/// (`livingReportBlock:dim:<key>`).
List<String> _dimensionBlockKeys() {
  final keys = <String>[];
  for (final element in find.byType(GestureDetector).evaluate()) {
    final key = element.widget.key;
    if (key is ValueKey<String> &&
        key.value.startsWith('livingReportBlock:dim:')) {
      keys.add(key.value.substring('livingReportBlock:dim:'.length));
    }
  }
  return keys;
}

void _printTable(Map<String, String> results) {
  debugPrint('\n================ 2237 E2E PASS/FAIL ================');
  for (final key in ['B', 'E', 'H', 'D', 'P', 'C', 'F', 'G']) {
    debugPrint('  $key: ${results[key] ?? "NOT RUN"}');
  }
  if (results.containsKey('LOGIN')) debugPrint('  LOGIN: ${results['LOGIN']}');
  debugPrint('====================================================\n');
}

Never failNow(String msg) => fail(msg); // flutter_test's fail() returns Never
