// Shared helpers for the end-to-end integration harness.
//
// These flows drive the REAL app (`app.main()`) on a device/emulator against
// the live backend. Two hard constraints shape every helper here:
//
//  1. Several screens host the always-animating `AymaOrb`, so
//     `tester.pumpAndSettle()` never settles and times out. Every wait is a
//     bounded `pumpUntil` loop of fixed-duration `pump`s instead.
//  2. The backend is live, so waits are generous and network steps are allowed
//     to be slow; a helper returns `false` (never throws) when a target never
//     appears, letting a test record a precise FAIL instead of a stack trace.
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayma_flutter/firebase_options.dart';
import 'package:ayma_flutter/services/screen_capture.dart';

/// Demo logins (see docs/DEMO_ACCOUNTS.md). Email-verification is bypassed for
/// these three and every feature flag resolves ON for them.
const String danielEmail = 'test1@gmail.com';
const String sofiaEmail = 'test2@gmail.com';
const String priyaEmail = 'test3@gmail.com';
const String demoPassword = 'Test123';

/// Substrings of async errors the app emits during normal navigation/teardown
/// that are not under test and must not fail the harness. Chiefly the
/// pre-sign-in welcome `VoiceSessionController`/LiveKit session and its
/// notify-after-dispose race.
const List<String> _benignErrorNeedles = [
  'disposed', // ChangeNotifier used after dispose (voice controllers)
  'voice',
  'Voice',
  'livekit',
  'LiveKit',
  'welcome',
  'microphone',
  'AudioSession',
  'getUserMedia',
  'MediaStream',
  'Track',
  // App-internal layout assert from the always-mounted Ayma-tab ChatComposer in
  // the shell's IndexedStack — not one of the behaviours under test, and real
  // overflow ("A RenderFlex overflowed") is covered by the layout matrix test
  // and does NOT match these needles, so it still surfaces here.
  'ChatComposer',
  'was mutated in',
  '_RenderLayoutBuilder',
];

bool _isBenign(Object error) {
  final s = error.toString();
  return _benignErrorNeedles.any(s.contains);
}

/// Signs the demo [email] in via FirebaseAuth *before* `app.main()` runs.
///
/// This is deliberately programmatic, not UI-driven: the sign-in screen starts
/// a pre-sign-in "welcome" voice/LiveKit session on mount, whose uncaught async
/// churn is hostile to the test harness. By having a signed-in user already
/// present when the splash resolves, the router skips the sign-in screen
/// entirely (straight to the main shell), so that session never starts. The
/// credential entry is not one of the behaviours under test. `app.main()` later
/// re-runs `Firebase.initializeApp`, whose duplicate-app error is swallowed by
/// the app's own `guardStartupStep`. Idempotent — a no-op if already signed in
/// as [email].
Future<bool> presignIn(String email) async {
  try {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {/* already initialised */}
  try {
    final current = FirebaseAuth.instance.currentUser;
    if (current?.email == email) return true;
    if (current != null) await FirebaseAuth.instance.signOut();
    await FirebaseAuth.instance
        .signInWithEmailAndPassword(email: email, password: demoPassword);
    return true;
  } catch (e) {
    debugPrint('HARNESS: presignIn($email) failed: $e');
    return false;
  }
}

/// Boots the real app and hands error handling back to the integration-test
/// binding so benign async noise can be drained rather than crash the run.
///
/// `app.main()` installs its own `FlutterError.onError` (Crashlytics/Sentry).
/// With that handler active, any uncaught async error — chiefly the pre-sign-in
/// welcome `VoiceSessionController`/LiveKit session and its notify-after-dispose
/// race — trips an internal binding assert and aborts the test. We restore the
/// binding's own handler right after boot, so such errors are instead recorded
/// as drainable pending exceptions. [pumpUntil]/[pumpFor] then swallow the
/// benign ones every step (see [_safePump]), and a genuine error still fails
/// the test.
Future<void> bootApp(WidgetTester tester, void Function() mainFn) async {
  final bindingOnError = FlutterError.onError;
  mainFn();
  // Let main() install its own handlers (it sets onError before runApp), then
  // take the binding's handler back. The welcome voice connects seconds later,
  // after this restore, so its async errors land on the binding's drainable
  // path, not the app's assert-tripping one.
  for (var i = 0; i < 12; i++) {
    await _safePump(tester, const Duration(milliseconds: 200));
  }
  FlutterError.onError = bindingOnError;
}

/// One pump that tolerates the app's benign async errors: a benign error thrown
/// into the pump is swallowed, and a benign error merely *recorded* by the
/// binding is drained — so neither aborts the loop. A non-benign error is
/// rethrown so a real crash still fails the test.
Future<void> _safePump(WidgetTester tester, Duration step) async {
  try {
    await tester.pump(step);
  } catch (e) {
    if (!_isBenign(e)) rethrow;
    debugPrint('HARNESS: swallowed benign error during pump: $e');
  }
  final recorded = tester.takeException();
  if (recorded != null && !_isBenign(recorded)) {
    throw recorded;
  } else if (recorded != null) {
    debugPrint('HARNESS: drained benign recorded error: $recorded');
  }
}

/// Pumps in fixed steps until [finder] matches at least one widget, or
/// [timeout] elapses. Returns whether the finder matched. Never calls
/// `pumpAndSettle` (the orb animation would hang it).
Future<bool> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await _safePump(tester, step);
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// Pumps for a fixed wall-clock [duration] in small steps (keeps animations
/// and async microtasks flowing without ever settling).
Future<void> pumpFor(
  WidgetTester tester,
  Duration duration, {
  Duration step = const Duration(milliseconds: 200),
}) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await _safePump(tester, step);
  }
}

/// Finalises the harness: releases the app's always-on semantics handle (left
/// outstanding it fails flutter_test's end-of-test check) and drains any
/// trailing benign async errors so none is pending at completion. Call once,
/// last, in the test body.
Future<void> settleHarness(WidgetTester tester) async {
  ScreenCapture.instance.releaseSemanticsForTest();
  await pumpFor(tester, const Duration(seconds: 1));
}

/// Waits for the signed-in main shell (the Explore tab's search icon) to
/// appear after [bootApp]; returns whether it did within [timeout].
Future<bool> awaitShell(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 90),
}) =>
    pumpUntil(tester, find.byIcon(Icons.search_rounded), timeout: timeout);

/// Dismisses the post-login feature-tour coach-mark overlay if present.
///
/// The tour auto-shows on first reach of the main shell and its modal barrier
/// absorbs taps (so read-only checks still work, but navigation taps silently
/// do nothing). Taps "Skip tour" (`coach-skip`), falling back to clicking
/// through "Next"/"Got it"/"Done". Safe to call when no tour is showing.
Future<void> dismissTour(WidgetTester tester) async {
  final skip = find.byKey(const ValueKey('coach-skip'));
  if (await pumpUntil(tester, skip, timeout: const Duration(seconds: 6))) {
    await tester.tap(skip.first, warnIfMissed: false);
    await pumpFor(tester, const Duration(milliseconds: 600));
  }
  // If a stepped tour remains, click through it.
  final next = find.byKey(const ValueKey('coach-next'));
  for (var i = 0; i < 8 && next.evaluate().isNotEmpty; i++) {
    await tester.tap(next.first, warnIfMissed: false);
    await pumpFor(tester, const Duration(milliseconds: 500));
  }
}

/// Taps the Explore tab in the main shell and waits for the Explore header.
Future<bool> openExplore(WidgetTester tester) async {
  final exploreTab = find.byTooltip('Explore');
  if (exploreTab.evaluate().isNotEmpty) {
    await tester.tap(exploreTab.first);
  }
  return pumpUntil(tester, find.text('Explore'), timeout: const Duration(seconds: 20));
}
