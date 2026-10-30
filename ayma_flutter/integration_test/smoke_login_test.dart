// Smoke test: boot the real app and sign in as Daniel, then dump what surface
// we landed on. Used to derisk the harness against the live backend before the
// full 8-behaviour suite. Run:
//   flutter test integration_test/smoke_login_test.dart -d emulator-5554
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayma_flutter/main.dart' as app;

import 'helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots and signs in as Daniel', (tester) async {
    final authed = await presignIn(danielEmail);
    debugPrint('SMOKE: presignIn=$authed');
    await bootApp(tester, app.main);
    final landed = await awaitShell(tester);

    // Report what we can see, regardless of pass/fail.
    final shell = find.byIcon(Icons.search_rounded).evaluate().isNotEmpty;
    debugPrint('SMOKE: signedInShell=$landed exploreIcon=$shell');
    for (final t in ['Biometric', 'consent', 'Preboarding', 'Verify']) {
      if (find.textContaining(t).evaluate().isNotEmpty) {
        debugPrint('SMOKE: blocked by screen containing "$t"');
      }
    }
    final onExplore = await openExplore(tester);
    debugPrint('SMOKE: openExplore=$onExplore exploreHeader='
        '${find.text('Explore').evaluate().isNotEmpty}');
    debugPrint('SMOKE: cards=${find.byType(GestureDetector).evaluate().length} '
        'daniel=${find.textContaining('Daniel').evaluate().isNotEmpty} '
        'sofia=${find.textContaining('Sofia').evaluate().isNotEmpty} '
        'priya=${find.textContaining('Priya').evaluate().isNotEmpty} '
        'maya=${find.textContaining('Maya').evaluate().isNotEmpty}');
    // Give the live feed up to 45s to populate; dump what renders.
    await pumpFor(tester, const Duration(seconds: 45));
    List<String?> texts() => find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .where((d) => d != null && d.trim().isNotEmpty)
        .toList();
    debugPrint('SMOKE: afterWait visibleTexts=${texts()}');
    debugPrint('SMOKE: gridViews=${find.byType(GridView).evaluate().length} '
        'images=${find.byType(Image).evaluate().length} '
        'loading=${find.byType(CircularProgressIndicator).evaluate().length} '
        'noOne=${find.textContaining('No one').evaluate().isNotEmpty} '
        'nothingHere=${find.textContaining('Nothing here').evaluate().isNotEmpty} '
        'couldNot=${find.textContaining('Could not').evaluate().isNotEmpty}');

    await settleHarness(tester);
    expect(landed, isTrue, reason: 'did not reach the signed-in main shell');
  });
}
