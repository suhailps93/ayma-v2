import 'dart:async';
import 'dart:io';

import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A fake backend for the Appearance pre-run sheet: returns the caller's whole
/// photo set already sorted into Face and Body buckets (§ founder 2026-10-28,
/// ISSUE 2 — all photos surfaced, not just the shot-type-tagged ones), and
/// records the appearance RUN so the test can prove "Run analysis" actually
/// fires the run (and with which ids). With [gated] the run stays in flight
/// until [completeRun], so a test can observe the in-flight (background) state.
class _FakeApi extends ApiClient {
  _FakeApi(this._elig, {this.gated = false})
      : super(auth: MockFirebaseAuth(signedIn: true));

  final AppearanceEligibility _elig;
  final bool gated;
  final Completer<AppearanceReportResult> _runGate =
      Completer<AppearanceReportResult>();

  int runCalls = 0;
  bool runCompleted = false;
  bool? ranWantFace;
  bool? ranWantBody;
  List<String>? ranFaceMediaIds;
  List<String>? ranBodyMediaIds;
  List<String> ranImagePaths = const [];

  @override
  Future<AppearanceEligibility> appearanceEligibility() async => _elig;

  @override
  Future<AppearanceReportResult> runAppearanceReport({
    List<String> imagePaths = const [],
    bool wantFace = true,
    bool wantBody = true,
    List<String>? faceMediaIds,
    List<String>? bodyMediaIds,
  }) async {
    runCalls++;
    ranWantFace = wantFace;
    ranWantBody = wantBody;
    ranFaceMediaIds = faceMediaIds;
    ranBodyMediaIds = bodyMediaIds;
    ranImagePaths = imagePaths;
    final result = gated
        ? await _runGate.future
        : const AppearanceReportResult(
            usageCapped: false, reportId: 'rid', report: null);
    runCompleted = true;
    return result;
  }

  /// Resolves a [gated] run — stands in for the server finishing the report.
  void completeRun() => _runGate.complete(const AppearanceReportResult(
      usageCapped: false, reportId: 'rid', report: null));
}

/// A fake PRIVATE upload channel. The real [ChatService.uploadImage] writes to
/// the caller's own `uploads/{uid}/…` tree — never the public grid. This fake
/// records every call and the prefix, so a test can prove the add-photo flow
/// goes through this private channel and never a public-profile/grid write.
class _FakeChat extends ChatService {
  int uploads = 0;
  final List<String> prefixes = [];

  @override
  Future<ChatImageUpload> uploadImage(File file, {String prefix = 'chat'}) async {
    uploads++;
    prefixes.add(prefix);
    final path = 'uploads/me/${prefix}_$uploads.jpg';
    return ChatImageUpload(
        storagePath: path, downloadUrl: 'https://cdn/$prefix$uploads.jpg');
  }
}

/// A private upload channel whose uploads stay in flight until [complete] or
/// [fail], so a test can observe the "Uploading…" spinner placeholder while an
/// add is pending and that it is swapped/removed when the upload resolves.
class _GatedChat extends ChatService {
  final Completer<ChatImageUpload> _gate = Completer<ChatImageUpload>();
  int uploads = 0;

  @override
  Future<ChatImageUpload> uploadImage(File file, {String prefix = 'chat'}) {
    uploads++;
    return _gate.future;
  }

  void complete() => _gate.complete(ChatImageUpload(
      storagePath: 'uploads/me/appearance_1.jpg',
      downloadUrl: 'https://cdn/a1.jpg'));

  void fail() => _gate.completeError(Exception('upload failed'));
}

/// Counts route pushes so a photo tap / Add tap can be proven NOT to navigate
/// (ISSUE 4 + the privacy fix: adding a photo must not open the public profile).
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

Future<void> _pumpSheet(
  WidgetTester tester,
  _FakeApi api,
  _PushCountObserver observer, {
  ChatService? chatService,
  Future<List<File>> Function()? pickImages,
}) async {
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [observer],
    home: Scaffold(
      body: AppearancePreRunSheet(
        api: api,
        chatService: chatService,
        pickImages: pickImages,
      ),
    ),
  ));
  // Resolve the eligibility future and rebuild with the populated buckets
  // (avoid pumpAndSettle — the network thumbnails never settle in tests).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  // MULTI-SELECT semantics (§ founder: real multi-select): each thumbnail is a
  // toggle, and every eligible/auto-select photo is ticked by default.
  const faceSelected = 'Photo selected for analysis, tap to remove';
  const faceUnselected = 'Tap to add this photo to the analysis';

  testWidgets('shows both Face and Body buckets populated from all photos, '
      'with an Add photo tile on each, and ALL auto-select photos pre-selected '
      'per axis', (tester) async {
    final observer = _PushCountObserver();
    await _pumpSheet(
        tester, _FakeApi(_eligWith(face: 3, body: 2)), observer);

    expect(find.text('Face analysis'), findsOneWidget);
    expect(find.text('Body analysis'), findsOneWidget);

    // Multi-select: EVERY auto-select photo is pre-ticked, so 3 Face + 2 Body
    // = 5 check badges (one per selected photo), not one per axis.
    expect(find.byIcon(Icons.check), findsNWidgets(5));
    // An Add photo tile in BOTH buckets (ISSUE 3): two 'Add' labels + icons.
    expect(find.text('Add'), findsNWidgets(2));
    expect(find.byIcon(Icons.add_a_photo_outlined), findsNWidgets(2));
  });

  testWidgets('renders the per-section guidance and the no-other-people note',
      (tester) async {
    final observer = _PushCountObserver();
    await _pumpSheet(
        tester, _FakeApi(_eligWith(face: 1, body: 1)), observer);

    // Each section says what photos it wants (the line also carries the live
    // selected count, e.g. "Clear photos of your face.  ·  1 selected"), and a
    // single prominent note warns against couple/group photos (§ founder
    // 2026-10-28).
    expect(find.textContaining('Clear photos of your face.'), findsOneWidget);
    expect(find.textContaining('Clear photos of your full body.'),
        findsOneWidget);
    expect(find.text('Use photos of just you — no other people.'),
        findsOneWidget);
  });

  testWidgets(
      'MULTI-SELECT: tapping a tile TOGGLES it (remove then re-add) and does '
      'NOT navigate', (tester) async {
    final observer = _PushCountObserver();
    // Body empty so every selected/unselected label is a Face tile — the axis
    // under test in isolation.
    await _pumpSheet(
        tester, _FakeApi(_eligWith(face: 2, body: 0)), observer);

    final pushesAfterOpen = observer.pushes; // the home route only
    // Both Face photos are pre-selected (multi-select default).
    expect(find.bySemanticsLabel(faceSelected), findsNWidgets(2));
    expect(find.bySemanticsLabel(faceUnselected), findsNothing);
    expect(find.byIcon(Icons.check), findsNWidgets(2));

    // Tap one selected tile -> it is REMOVED from the set (toggle off), leaving
    // one selected and one unselected — the others are untouched (no replace).
    await tester.tap(find.bySemanticsLabel(faceSelected).first);
    await tester.pump();
    expect(find.bySemanticsLabel(faceSelected), findsOneWidget);
    expect(find.bySemanticsLabel(faceUnselected), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    // Tap the now-unselected tile -> it is ADDED back (toggle on): both selected
    // again, so toggling is additive, not a single-pick replace.
    await tester.tap(find.bySemanticsLabel(faceUnselected));
    await tester.pump();
    expect(find.bySemanticsLabel(faceSelected), findsNWidgets(2));
    expect(find.byIcon(Icons.check), findsNWidgets(2));

    // The crux of ISSUE 4: a photo tap must never push a route.
    expect(observer.pushes, pushesAfterOpen);
  });

  testWidgets(
      'MULTI-SELECT: Run sends ALL ticked media ids per axis, in grid order, '
      'and a de-ticked photo is dropped from the run', (tester) async {
    final api = _FakeApi(_eligWith(face: 3, body: 1));

    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (c, s) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => runAppearanceFromPreRunSheet(c, api),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // sheet + eligibility
    expect(find.text('Run analysis'), findsOneWidget);

    // All three Face photos (f0,f1,f2) and the one Body photo (b0) start ticked
    // (the selected label is shared across axes: 3 face + 1 body = 4). The tiles
    // render in section order, so index 1 is the middle Face photo, f1.
    expect(find.bySemanticsLabel(faceSelected), findsNWidgets(4));
    // De-tick the MIDDLE Face photo (f1) so the run must reflect the change.
    await tester.tap(find.bySemanticsLabel(faceSelected).at(1));
    await tester.pump();

    await tester.tap(find.text('Run analysis'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // sheet gone -> run fires

    expect(api.runCalls, 1);
    // ALL still-ticked ids are sent, in grid order, with f1 dropped — proving
    // the run reads the whole selected set, not just the first photo (the old
    // stale-report bug), and that a changed selection drives the new set.
    expect(api.ranFaceMediaIds, ['f0', 'f2']);
    expect(api.ranBodyMediaIds, ['b0']);
    expect(api.ranImagePaths, isEmpty);
  });

  testWidgets(
      'shows an Uploading… spinner while an add is in flight, then swaps in '
      'the real tile on success', (tester) async {
    final observer = _PushCountObserver();
    final chat = _GatedChat();
    await _pumpSheet(
      tester,
      _FakeApi(_eligWith(face: 1, body: 1)),
      observer,
      chatService: chat,
      pickImages: () async => [File('/tmp/picked.jpg')],
    );

    // 1 face + 1 body = 2 selected to start, nothing uploading.
    expect(find.byIcon(Icons.check), findsNWidgets(2));
    expect(find.text('Uploading…'), findsNothing);

    // Tap the Face group's Add tile; the upload is gated (still in flight).
    await tester.tap(find.text('Add').first);
    await tester.pump(); // picker resolves, spinner placeholder inserted
    await tester.pump(const Duration(milliseconds: 10));

    // A spinner placeholder is visible, but no new tile yet.
    expect(find.text('Uploading…'), findsOneWidget);
    expect(find.byType(AymaWingLoader), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNWidgets(2));

    // The upload completes -> placeholder gone, the new tile JOINS the Face
    // selection (multi-select: added to the existing f0, not a replace), so the
    // count rises to 3 (f0 + the new Face pick + the unchanged Body pick).
    chat.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Uploading…'), findsNothing);
    expect(find.byType(AymaWingLoader), findsNothing);
    expect(find.byIcon(Icons.check), findsNWidgets(3));
  });

  testWidgets(
      'removes the spinner and shows an inline error when an add upload fails',
      (tester) async {
    final observer = _PushCountObserver();
    final chat = _GatedChat();
    await _pumpSheet(
      tester,
      _FakeApi(_eligWith(face: 1, body: 1)),
      observer,
      chatService: chat,
      pickImages: () async => [File('/tmp/picked.jpg')],
    );

    await tester.tap(find.text('Add').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Uploading…'), findsOneWidget);

    // The upload fails -> placeholder removed, no new tile, an error toast.
    chat.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Uploading…'), findsNothing);
    expect(find.byIcon(Icons.check), findsNWidgets(2)); // no tile added
    expect(find.text("Couldn't add that photo."), findsOneWidget);
  });

  testWidgets(
      'PRIVACY: Add photo uploads through the private channel, never '
      'navigates to the public profile, never publishes', (tester) async {
    final observer = _PushCountObserver();
    final chat = _FakeChat();
    await _pumpSheet(
      tester,
      _FakeApi(_eligWith(face: 1, body: 1)),
      observer,
      chatService: chat,
      pickImages: () async => [File('/tmp/picked.jpg')],
    );

    final pushesAfterOpen = observer.pushes;
    // 1 face + 1 body = 2 selected to start.
    expect(find.byIcon(Icons.check), findsNWidgets(2));

    // Tap the Face group's Add tile (the first of the two Add tiles).
    await tester.tap(find.text('Add').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The photo went through the PRIVATE upload channel, with the appearance
    // prefix — never a public-grid write and never a navigation.
    expect(chat.uploads, 1);
    expect(chat.prefixes, ['appearance']);
    // No route was pushed: the public-profile editor was never opened.
    expect(observer.pushes, pushesAfterOpen);
    // The added photo JOINS the Face selection (multi-select: added to f0), so
    // the count rises to 3 (f0 + new Face pick + unchanged Body pick).
    expect(find.byIcon(Icons.check), findsNWidgets(3));
  });

  testWidgets(
      'Run analysis fires the run in the BACKGROUND (no blocking dialog, no '
      'forced navigation) with the selected ids; a privately-added photo rides '
      'as image_paths, never as a grid media id', (tester) async {
    final api = _FakeApi(_eligWith(face: 1, body: 1), gated: true);
    final chat = _FakeChat();

    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (c, s) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => runAppearanceFromPreRunSheet(
                  c,
                  api,
                  chatService: chat,
                  pickImages: () async => [File('/tmp/picked.jpg')],
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
        // The chat shell — if "Run analysis" wrongly opened chat we'd land here.
        GoRoute(
            path: '/', builder: (c, s) => const Scaffold(body: Text('CHAT SHELL'))),
        GoRoute(
          path: '/appearance/:id',
          builder: (c, s) =>
              Scaffold(body: Text('REPORT ${s.pathParameters['id']}')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.tap(find.text('go'));
    await tester.pump(); // open sheet
    await tester.pump(const Duration(seconds: 1)); // sheet entrance + eligibility
    expect(find.text('Run analysis'), findsOneWidget);

    // Add a private face photo, then run.
    await tester.tap(find.text('Add').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.uploads, 1);

    await tester.tap(find.text('Run analysis'));
    await tester.pump(); // begin sheet dismissal
    await tester.pump(const Duration(seconds: 1)); // sheet gone -> run fires

    // The run fired exactly once and is still in flight (gated) — the UI did
    // NOT block on it.
    expect(api.runCalls, 1);
    expect(api.runCompleted, isFalse);
    // Multi-select: adding a Face photo ADDS to the default grid pick (f0), so
    // Face still carries its grid media id f0, while the privately-added photo
    // rides separately as an image_path. Body keeps its single grid pick.
    expect(api.ranFaceMediaIds, ['f0']);
    expect(api.ranBodyMediaIds, ['b0']);
    // ...and the privately-added photo went ONLY as an image_path (a private
    // uploads/ path), never smuggled into the grid media-id lists.
    expect(api.ranImagePaths.length, 1);
    expect(api.ranImagePaths.single.startsWith('uploads/'), isTrue);
    expect(api.ranFaceMediaIds, isNot(contains(api.ranImagePaths.single)));

    // A non-blocking acknowledgement toast — never a report navigation and
    // never the chat shell.
    expect(find.textContaining('Running your analysis'), findsOneWidget);
    expect(find.text('REPORT rid'), findsNothing);
    expect(find.text('REPORT current'), findsNothing);
    expect(find.text('CHAT SHELL'), findsNothing);

    // When the background run lands it surfaces a ready toast — still no forced
    // navigation (the report card refresh is the real signal).
    api.completeRun();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.runCompleted, isTrue);
    expect(find.textContaining('ready'), findsOneWidget);
    expect(find.text('REPORT rid'), findsNothing);
  });

  testWidgets(
      'navigating away during a run does NOT cancel it — the result still lands',
      (tester) async {
    final api = _FakeApi(_eligWith(face: 1, body: 0), gated: true);

    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (c, s) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => runAppearanceFromPreRunSheet(c, api),
                child: const Text('go'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/away', builder: (c, s) => const Scaffold(body: Text('AWAY'))),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Run analysis'), findsOneWidget);

    await tester.tap(find.text('Run analysis'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // sheet gone -> run in flight
    expect(api.runCalls, 1);
    expect(api.runCompleted, isFalse);

    // The user leaves (Back / navigate away) while the run is in flight. The
    // originating screen is torn down.
    router.go('/away');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('AWAY'), findsOneWidget);
    expect(find.text('Run analysis'), findsNothing);

    // The in-flight run finishes server-side — leaving did NOT cancel it, and
    // no unhandled error is raised when the (now-unmounted) caller completes.
    api.completeRun();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.runCompleted, isTrue);
  });
}
