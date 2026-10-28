import 'dart:io';

import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A fake backend for the Appearance pre-run sheet: returns the caller's whole
/// photo set already sorted into Face and Body buckets (§ founder 2026-10-28,
/// ISSUE 2 — all photos surfaced, not just the shot-type-tagged ones), and
/// records the appearance RUN so the test can prove "Run analysis" actually
/// POSTs the run (and with which ids) rather than opening the chat.
class _FakeApi extends ApiClient {
  _FakeApi(this._elig) : super(auth: MockFirebaseAuth(signedIn: true));

  final AppearanceEligibility _elig;

  int runCalls = 0;
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
    return const AppearanceReportResult(
        usageCapped: false, reportId: 'rid', report: null);
  }
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
    // The added photo shows as a new, pre-selected tile (now 3 checks).
    expect(find.byIcon(Icons.check), findsNWidgets(3));
  });

  testWidgets(
      'Run analysis POSTs the appearance run with the selected ids and opens '
      'the report in-place — it does NOT open the chat; a privately-added '
      'photo rides as image_paths, never as a grid media id', (tester) async {
    final api = _FakeApi(_eligWith(face: 1, body: 1));
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
        GoRoute(path: '/', builder: (c, s) => const Scaffold(body: Text('CHAT SHELL'))),
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
    await tester.pump(); // run future resolves, dialog pops
    await tester.pump(const Duration(seconds: 1)); // navigation settles

    // The run actually happened, exactly once.
    expect(api.runCalls, 1);
    // Grid selections went as media ids...
    expect(api.ranFaceMediaIds, ['f0']);
    expect(api.ranBodyMediaIds, ['b0']);
    // ...and the privately-added photo went ONLY as an image_path (a private
    // uploads/ path), never smuggled into the grid media-id lists.
    expect(api.ranImagePaths.length, 1);
    expect(api.ranImagePaths.single.startsWith('uploads/'), isTrue);
    expect(api.ranFaceMediaIds, isNot(contains(api.ranImagePaths.single)));

    // We opened the report in-place, and NEVER the chat shell.
    expect(find.text('REPORT rid'), findsOneWidget);
    expect(find.text('CHAT SHELL'), findsNothing);
  });
}
