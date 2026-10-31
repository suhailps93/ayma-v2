import 'package:ayma_flutter/dev_mode.dart';
import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/screens/admin_feedback_screen.dart';
import 'package:ayma_flutter/screens/developer_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The compile-time dev-mode gate (lib/dev_mode.dart) and its effect on the
/// router. In the plain `flutter test` environment no `--dart-define` is
/// passed, so `kDevModeEnabled` is at its fail-safe default (false) — the
/// customer / store configuration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('kDevModeEnabled defaults to false (customer / store build)', () {
    // No --dart-define=ENABLE_DEV_MODE in the test harness.
    expect(kDevModeEnabled, isFalse);
    expect(devModeEnabled, isFalse);
  });

  test('devModeEnabled honours the test override, then falls back', () {
    expect(devModeEnabled, isFalse);
    debugDevModeOverride = true;
    expect(devModeEnabled, isTrue);
    debugDevModeOverride = null;
    expect(devModeEnabled, isFalse);
  });

  test('the Developer and dev-only routes are redirect-gated, normal routes '
      'are not', () {
    // The dev routes stay in the table (so the app-registry invariant holds)
    // but carry a redirect that bounces them to the main shell unless dev mode
    // is on. A normal route like /settings has no such gate.
    final byPath = <String, GoRoute>{
      for (final r in appRouter.configuration.routes)
        if (r is GoRoute) r.path: r,
    };
    for (final p in [
      DeveloperScreen.path,
      AymaNotesScreen.path,
      AdminFeedbackScreen.path,
    ]) {
      expect(byPath.containsKey(p), isTrue, reason: '$p should be registered');
      expect(byPath[p]!.redirect, isNotNull,
          reason: '$p must be gated by a redirect');
    }
    expect(byPath['/settings'], isNotNull);
    expect(byPath['/settings']!.redirect, isNull,
        reason: 'a normal route is not dev-gated');
  });
}
