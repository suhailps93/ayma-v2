import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

/// Disable google_fonts runtime HTTP fetching for the whole test suite.
///
/// Why this exists (store blocker, 2026-11-09): most widget tests run under a
/// fake clock, where the google_fonts fetch future is scheduled but never
/// completes, so google_fonts silently falls back to its bundled font and
/// never throws. But a test that drives state inside `tester.runAsync` (e.g.
/// `tour_host_voice_suppression_test.dart`) runs real async, so the real HTTP
/// fetch to fonts.gstatic.com actually fires. On clean CI (and any machine
/// with a cold font cache) that fetch returns 400 under the test binding and
/// google_fonts throws `Failed to load font with url: ...`, failing the test
/// and blocking the store build. Turning off runtime fetching here makes every
/// test deterministically use the bundled fallback with no network, which is
/// the behaviour uncached tests already relied on. Test-only; no product code
/// and no assertions are affected.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}
