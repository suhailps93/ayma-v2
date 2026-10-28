import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake backend for the Appearance pre-run sheet: returns the caller's whole
/// photo set already sorted into Face and Body buckets (§ founder 2026-10-28,
/// ISSUE 2 — all photos surfaced, not just the shot-type-tagged ones).
class _FakeApi extends ApiClient {
  _FakeApi(this._elig) : super(auth: MockFirebaseAuth(signedIn: true));

  final AppearanceEligibility _elig;

  @override
  Future<AppearanceEligibility> appearanceEligibility() async => _elig;
}

/// Counts route pushes so a photo tap can be proven NOT to navigate (ISSUE 4).
class _PushCountObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

AppearanceEligibility _eligWith({required int face, required int body}) =>
    AppearanceEligibility(
      face: [
        for (var i = 0; i < face; i++)
          EligiblePhoto(mediaId: 'f$i', url: 'https://cdn/f$i.jpg'),
      ],
      body: [
        for (var i = 0; i < body; i++)
          EligiblePhoto(mediaId: 'b$i', url: 'https://cdn/b$i.jpg'),
      ],
    );

Future<void> _pumpSheet(WidgetTester tester, _FakeApi api,
    _PushCountObserver observer) async {
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [observer],
    home: Scaffold(body: AppearancePreRunSheet(api: api)),
  ));
  // Resolve the eligibility future and rebuild with the populated buckets
  // (avoid pumpAndSettle — the network thumbnails never settle in tests).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  const faceIncluded = 'Photo included — tap to leave out';
  const faceExcluded = 'Photo left out — tap to include';

  testWidgets('shows both Face and Body buckets populated from all photos, '
      'with an Add photo tile on each', (tester) async {
    final observer = _PushCountObserver();
    await _pumpSheet(
        tester, _FakeApi(_eligWith(face: 3, body: 2)), observer);

    expect(find.text('Face analysis'), findsOneWidget);
    expect(find.text('Body analysis'), findsOneWidget);

    // Every pooled photo (3 + 2) starts selected -> 5 check badges.
    expect(find.byIcon(Icons.check), findsNWidgets(5));
    // An Add photo tile in BOTH buckets (ISSUE 3): two 'Add' labels + icons.
    expect(find.text('Add'), findsNWidgets(2));
    expect(find.byIcon(Icons.add_a_photo_outlined), findsNWidgets(2));
  });

  testWidgets('tapping a photo toggles its selection and does NOT navigate',
      (tester) async {
    final observer = _PushCountObserver();
    await _pumpSheet(
        tester, _FakeApi(_eligWith(face: 2, body: 1)), observer);

    final pushesAfterOpen = observer.pushes; // the home route only
    expect(find.bySemanticsLabel(faceIncluded), findsNWidgets(3));
    expect(find.bySemanticsLabel(faceExcluded), findsNothing);

    // Deselect one photo.
    await tester.tap(find.bySemanticsLabel(faceIncluded).first);
    await tester.pump();

    expect(find.bySemanticsLabel(faceExcluded), findsOneWidget);
    expect(find.bySemanticsLabel(faceIncluded), findsNWidgets(2));
    expect(find.byIcon(Icons.check), findsNWidgets(2));

    // Re-select it.
    await tester.tap(find.bySemanticsLabel(faceExcluded));
    await tester.pump();
    expect(find.bySemanticsLabel(faceIncluded), findsNWidgets(3));

    // The crux of ISSUE 4: a photo tap must never push a route.
    expect(observer.pushes, pushesAfterOpen);
  });
}
