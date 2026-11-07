import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/deep_dive_activity.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/ayma_rail_icons.dart';
import 'package:ayma_flutter/widgets/living_report_view.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serves one local fixture file for any URL, so header photos (rendered
/// through [AymaPhoto] → [CachedNetworkImage]) run their real decode
/// pipeline with no sqflite cache database and no network.
class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
    : file = const LocalFileSystem().file(ioFile.path);

  // flutter_cache_manager's API speaks package:file's File type.
  final fs.File file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async => file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Map<String, dynamic> _profile({
  bool self = false,
  bool liked = false,
  double? score,
  bool hasChatted = false,
  String deepDiveId = '',
  List<String> photos = const [],
  List<String>? photosThumb,
  List<String>? photosMedium,
  List<Map<String, dynamic>> pages = const [
    {'page_type': 'identity', 'title': '', 'body': 'From Lisbon, lives in Berlin.'},
    {'page_type': 'interests', 'title': '', 'body': 'Climbs and cooks.'},
  ],
}) =>
    {
      'uid': 'her',
      'self': self,
      'blocked': false,
      'name': 'Dana',
      'age': 30,
      'location': 'Berlin',
      'photos': photos,
      if (photosThumb != null) 'photos_thumb': photosThumb,
      if (photosMedium != null) 'photos_medium': photosMedium,
      'pages': pages,
      'liked': liked,
      'score': score,
      // A bare deterministic pair id, present for any non-self profile
      // whether or not the pair has actually chatted — see `has_chatted`.
      'thread_id': self ? null : 'her__me',
      'has_chatted': !self && hasChatted,
      'deep_dive_id': deepDiveId,
    };

/// The `GET /report/public_profile/her` payload the backend derives from
/// the SAME pages `/explore/profile` serves (see
/// `report_adapters.public_profile_blocks` — one text block per page here;
/// sentence-splitting granularity is the server's own business).
Map<String, dynamic> _reportFromProfile(Map<String, dynamic> profile) {
  const labels = {
    'identity': 'Identity',
    'career': 'Work & study',
    'interests': 'Interests',
    'personality': 'Personality',
    'values': 'Values',
    'goals': 'Looking ahead',
    'lifestyle': 'Lifestyle',
    'family': 'Family',
    'relationships': 'Relationships',
    'misc': 'More',
  };
  final pages = (profile['pages'] as List).cast<Map<String, dynamic>>();
  return {
    'title': profile['name'],
    'sections': [
      for (var i = 0; i < pages.length; i++)
        {
          'heading': (pages[i]['title'] as String? ?? '').isNotEmpty
              ? pages[i]['title']
              : (labels[pages[i]['page_type']] ?? 'More'),
          'blocks': [
            {
              'block_id': 'sec:$i:sent:0',
              'type': 'text',
              'editable': false,
              'text': pages[i]['body'],
            },
          ],
        },
    ],
    'meta': {
      'owner_uid': profile['uid'],
      'viewer_can_edit': false,
      'created_at': null,
      'updated_at': null,
    },
  };
}

ApiClient _api(
  Map<String, dynamic> profile, {
  void Function(String path)? onPost,
  Map<String, dynamic>? compat,
  bool likeMutual = false,
  Map<String, dynamic>? deepDive,
  int failLikes = 0,
}) {
  var likeFailuresLeft = failLikes;
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore/profile/her') {
        return http.Response(jsonEncode(profile), 200);
      }
      if (req.url.path == '/report/public_profile/her' ||
          req.url.path == '/report/story_public/her') {
        return http.Response(jsonEncode(_reportFromProfile(profile)), 200);
      }
      if (req.method == 'POST') {
        onPost?.call(req.url.path);
        if (req.url.path == '/explore/like') {
          if (likeFailuresLeft > 0) {
            likeFailuresLeft--;
            return http.Response('no', 500);
          }
          return http.Response(
              jsonEncode({'ok': true, 'mutual': likeMutual}), 200);
        }
        if (req.url.path == '/explore/unlike') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (req.url.path == '/deep-dive') {
          return http.Response(
              jsonEncode(deepDive ?? {'queued': true, 'is_self': false}), 200);
        }
        if (req.url.path == '/check-compatibility') {
          return http.Response(
            jsonEncode(compat ?? {'ok': true, 'score': 0.67, 'match_id': 'm'}),
            200,
          );
        }
      }
      return http.Response('no', 404);
    }),
  );
}

Widget _app(ApiClient api, {List<String>? pushed}) {
  final router = GoRouter(
    initialLocation: '/profile/user/her',
    routes: [
      GoRoute(
        path: '/profile/user/:uid',
        builder: (_, s) =>
            PublicProfileScreen(uid: s.pathParameters['uid']!, api: api),
      ),
      GoRoute(
        path: '/dm/:threadId',
        builder: (_, s) {
          pushed?.add(s.pathParameters['threadId']!);
          return const Scaffold(body: Text('DM THREAD'));
        },
      ),
      GoRoute(
        path: '/match/:matchId',
        builder: (_, s) {
          pushed?.add('/match/${s.pathParameters['matchId']}');
          return const Scaffold(body: Text('MATCH REPORT'));
        },
      ),
      GoRoute(
        path: '/deep-dive/:reportId',
        builder: (_, s) {
          pushed?.add('/deep-dive/${s.pathParameters['reportId']}');
          return const Scaffold(body: Text('DEEP DIVE REPORT'));
        },
      ),
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
      GoRoute(
        path: '/profile/plan',
        builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

/// Whether the glyph of type [glyphType] sits on ANY circular filled
/// `Material`/`DecoratedBox` (`shape: CircleBorder`/`BoxShape.circle`) —
/// founder ask, 2026-09-22 revision: neither state draws a disc/button
/// background behind the icon at all, not even "done" — the rail button's
/// `_RailButton` build now only ever wraps the glyph in a bare
/// `Padding`+`IconTheme`, so this must come back `false` for every state.
bool _hasCircleBehind(WidgetTester tester, Type glyphType) {
  return find
      .ancestor(
        of: find.byWidgetPredicate((w) => w.runtimeType == glyphType),
        matching: find.byWidgetPredicate((w) =>
            (w is Material && w.shape is CircleBorder) ||
            (w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle)),
      )
      .evaluate()
      .isNotEmpty;
}

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
    // The screen now carries its own persistent tab bar (§ `AymaTabBar`),
    // whose first tab is a live `AymaOrb` — its ambient motion runs on a
    // never-ending `AnimationController.repeat()` (see that widget's own
    // `_syncMotion`), which is exactly what `disableAnimations` (the
    // accessibility "reduce motion" signal it already checks) turns off.
    // Without this, every `pumpAndSettle()` below — this file's standing
    // pattern — would hang forever waiting for a frame that never stops
    // being scheduled.
    b.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    // A test that opens the popup and never dismisses it leaves
    // `showAymaChatModal`'s awaited Future pending forever once `tester`'s
    // own teardown discards the widget tree out from under it, so this
    // top-level flag never gets the chance to flip back — reset it
    // explicitly so it can't leak a false "already open" into a later test.
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
    b.platformDispatcher.views.first.resetDevicePixelRatio();
    b.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  testWidgets('opening a profile sets the voice screen-context', (tester) async {
    addTearDown(AppContext.instance.clear);
    AppContext.instance.clear();

    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pump(); // initState, before the profile future resolves
    expect(AppContext.instance.current.value.screen, 'profile');
    expect(AppContext.instance.current.value.subjectUid, 'her');

    await tester.pumpAndSettle(); // name arrives
    expect(AppContext.instance.current.value.subjectName, 'Dana');
  });

  testWidgets('renders the public sections and actions', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(find.text('Dana'), findsWidgets); // title bar + header
    expect(find.text('From Lisbon, lives in Berlin.'), findsOneWidget);
    expect(find.text('Climbs and cooks.'), findsOneWidget);
    // Section headings — from the report's own sections now, uppercased by
    // the shared renderer exactly as the old bespoke body uppercased its
    // page-type labels.
    expect(find.text('IDENTITY'), findsOneWidget);
    expect(find.text('INTERESTS'), findsOneWidget);
    // Icon-only rail (founder ask, 2026-09-22: "double the icon size, remove
    // the text below") — no "Chat"/"Like"/"Match"/"Web search" labels or
    // credit captions any more, just the four glyphs, each starting in its
    // outline ("not done") state for a fresh, never-interacted-with pair.
    expect(find.byType(AymaHeartGlyph), findsOneWidget);
    expect(find.byType(AymaChatGlyph), findsOneWidget);
    expect(find.byType(AymaSearchGlyph), findsOneWidget);
    expect(find.byType(AymaMatchGlyph), findsOneWidget);
    expect(
        tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isFalse);
    expect(tester.widget<AymaChatGlyph>(find.byType(AymaChatGlyph)).filled,
        isFalse);
    expect(
        tester.widget<AymaSearchGlyph>(find.byType(AymaSearchGlyph)).filled,
        isFalse);
    expect(tester.widget<AymaMatchGlyph>(find.byType(AymaMatchGlyph)).filled,
        isFalse);
  });

  // One shared body for every profile view: a non-self profile renders the
  // read-only `public_profile` report, the self view the You tab's editable
  // `story_public` report, both through the same [ProfileBody].
  testWidgets(
      'a non-self profile renders ProfileBody over the public_profile report '
      'with the photo header intact', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileBody), findsOneWidget);
    final view = tester
        .widget<LivingReportView>(find.byType(LivingReportView));
    expect(view.reportType, 'public_profile');
    expect(view.reportId, 'her');
    expect(find.byType(ProfilePhotoHeader), findsOneWidget);
    expect(find.text('From Lisbon, lives in Berlin.'), findsOneWidget);
  });

  testWidgets(
      'the self view renders the same ProfileBody over the story_public '
      'report, exactly as the You tab page does', (tester) async {
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileBody), findsOneWidget);
    final view = tester
        .widget<LivingReportView>(find.byType(LivingReportView));
    expect(view.reportType, 'story_public');
    expect(view.reportId, 'her');
    expect(find.byType(ProfilePhotoHeader), findsOneWidget);
  });

  testWidgets('Chat opens the DM thread', (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(_app(_api(_profile()), pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AymaChatGlyph));
    await tester.pumpAndSettle();
    expect(pushed, ['her__me']);
  });

  // Regression for the false "already chatted" bug: `thread_id` is a bare
  // deterministic sorted-pair id present for ANY non-self profile — opening
  // this screen (or even just viewing it) must never light the Chat button
  // up on its own. Only a server-confirmed `has_chatted` (a real message
  // sent either way) may do that.
  testWidgets(
      'Chat is NOT highlighted merely because a thread_id is present '
      '(no real message sent yet)', (tester) async {
    await tester.pumpWidget(_app(_api(_profile(hasChatted: false))));
    await tester.pumpAndSettle();

    // Chat must read exactly like any other never-done action (e.g. the
    // not-yet-liked Like button) — outline only, not the "done" accent fill.
    expect(tester.widget<AymaChatGlyph>(find.byType(AymaChatGlyph)).filled,
        isFalse);
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isFalse);
  });

  testWidgets(
      'Chat IS highlighted once a real message has actually been sent',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile(hasChatted: true))));
    await tester.pumpAndSettle();

    // Chat already reads as "done" (server-confirmed has_chatted) before any
    // tap — same filled treatment Like gets once it flips to its own "done"
    // state.
    expect(tester.widget<AymaChatGlyph>(find.byType(AymaChatGlyph)).filled,
        isTrue);

    await tester.tap(find.byType(AymaHeartGlyph)); // flips Like to its "done" fill
    await tester.pumpAndSettle();

    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);
  });

  // State-mapping for the Web-search glyph (2026-09-26 icon-family redesign:
  // the icon's own outline-vs-filled rendering is the only status signal):
  // completed = the profile's real deep-dive report state (`deep_dive_id`
  // non-empty), never anything invented client-side.
  testWidgets(
      'Web search stays outline while no deep-dive report exists',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile(deepDiveId: ''))));
    await tester.pumpAndSettle();

    expect(
        tester.widget<AymaSearchGlyph>(find.byType(AymaSearchGlyph)).filled,
        isFalse);
  });

  testWidgets(
      'Web search reads filled once a deep-dive report exists, and tapping '
      'it opens that report', (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(
        _app(_api(_profile(deepDiveId: 'dd1')), pushed: pushed));
    await tester.pumpAndSettle();

    expect(
        tester.widget<AymaSearchGlyph>(find.byType(AymaSearchGlyph)).filled,
        isTrue);

    await tester.tap(find.byType(AymaSearchGlyph));
    await tester.pumpAndSettle();
    expect(pushed, contains('/deep-dive/dd1'));
    expect(find.text('DEEP DIVE REPORT'), findsOneWidget);
  });

  testWidgets(
      'tapping Web search with no report only navigates to the deep-dive screen '
      'with a uid_<x> id and starts no search', (tester) async {
    final pushed = <String>[];
    final posts = <String>[];
    await tester.pumpWidget(_app(
        _api(_profile(deepDiveId: ''), onPost: posts.add), pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AymaSearchGlyph));
    await tester.pumpAndSettle();

    // The entry point only navigates and never hits the run endpoint.
    expect(posts, isEmpty);
    expect(pushed, contains('/deep-dive/uid_her'));
    expect(find.text('DEEP DIVE REPORT'), findsOneWidget);
    expect(DeepDiveActivity.instance.isSearching('her'), isFalse);
  });

  testWidgets('Like posts and flips the heart glyph to its filled "done" state',
      (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(_app(_api(_profile(), onPost: posts.add)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();

    expect(posts, contains('/explore/like'));
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);
  });

  testWidgets('a refused like offers Retry, which sends the same like',
      (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(
        _app(_api(_profile(), onPost: posts.add, failLikes: 1)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't send that like."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isFalse);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(posts, ['/explore/like', '/explore/like']);
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);
  });

  testWidgets(
      'tapping the filled heart glyph posts /explore/unlike and flips it '
      'back to outline', (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(
        _app(_api(_profile(liked: true), onPost: posts.add)));
    await tester.pumpAndSettle();

    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);

    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();

    expect(posts, contains('/explore/unlike'));
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isFalse);
  });

  testWidgets('unliking a mutual like confirms first', (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(_app(
        _api(_profile(), onPost: posts.add, likeMutual: true)));
    await tester.pumpAndSettle();

    // Like in-session so the screen knows it's mutual.
    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);

    // Unlike → a confirm dialog; dismiss it and nothing is posted.
    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();
    expect(find.text('Remove your like?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(posts, isNot(contains('/explore/unlike')));
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);

    // Confirm this time → it posts and flips back.
    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(posts, contains('/explore/unlike'));
    expect(tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isFalse);
  });

  // Founder ask, 3rd reference (moodboard) — rejected the earlier "done ="
  // solid accent circle" treatment outright: the reference has NO disc/
  // button background behind either state, only ever. "Done" is the solid
  // filled glyph itself (with its own glow — see `ayma_rail_icons.dart`),
  // not a circle wrapped around it.
  testWidgets(
      'a rail button never draws a filled circle behind its icon, not-yet-'
      'done or done', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(_hasCircleBehind(tester, AymaHeartGlyph), isFalse);
    expect(
        tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isFalse);

    await tester.tap(find.byType(AymaHeartGlyph));
    await tester.pumpAndSettle();

    expect(_hasCircleBehind(tester, AymaHeartGlyph), isFalse);
    expect(
        tester.widget<AymaHeartGlyph>(find.byType(AymaHeartGlyph)).filled,
        isTrue);
  });

  // Founder ask: "make sure the bottom nav bar is visible in all pages" —
  // flagged specifically on this screen (a profile reached from Explore),
  // which used to have no bottom bar at all once pushed on top of the shell.
  testWidgets(
      'the screen shows its own persistent tab bar, and tapping a tab '
      'returns to the shell', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Ayma'), findsOneWidget);
    expect(find.byTooltip('Explore'), findsOneWidget);
    expect(find.byTooltip('Messages'), findsOneWidget);
    expect(find.byTooltip('Profile'), findsOneWidget);

    expect(find.text('SHELL'), findsNothing);
    await tester.tap(find.byTooltip('Explore'));
    await tester.pumpAndSettle();
    expect(find.text('SHELL'), findsOneWidget);
  });

  // Founder ask: tapping the orb from anywhere but the Ayma tab itself opens
  // the scoped page-context popup ("like the story edit") instead of
  // navigating away — this screen carries its own copy of `AymaTabBar` (see
  // `_goToTab`'s doc), so it needs the same fix `NavBarShell` got.
  testWidgets(
      'tapping the orb opens the page-context popup instead of returning to '
      'the shell', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ayma'));
    await tester.pumpAndSettle();

    expect(find.text('SHELL'), findsNothing);
    expect(find.byKey(const ValueKey('aymaChatModalHandle')), findsOneWidget);
  });

  // A second orb tap while the popup is docked closes it and navigates to
  // the real main chat screen (the shell route) — it does not grow the
  // overlay to full screen in place.
  testWidgets(
      'tapping the orb again while the popup is open closes it and goes '
      'to the shell (real main chat screen)', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ayma'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('aymaChatModalHandle')), findsOneWidget);

    // The popup carries its own on-top copy of this bar (so it stays
    // visible/tappable while open — see `ayma_chat_modal.dart`'s
    // `persistentBottomBar`); address that copy specifically since the real
    // one underneath is still mounted too.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('aymaChatModalNavBar')),
        matching: find.byTooltip('Ayma'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('aymaChatModalHandle')), findsNothing);
    expect(isAymaSheetOpen, isFalse);
    expect(aymaSheet.isExpanded, isFalse);
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('Run match calls the endpoint and opens the report',
      (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(_app(_api(_profile()), pushed: pushed));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AymaMatchGlyph));
    await tester.pumpAndSettle();

    // Scored, then routed straight to the shareable match report.
    expect(pushed, contains('/match/m'));
    expect(find.text('MATCH REPORT'), findsOneWidget);
  });

  testWidgets(
      'a scored pair shows the match glyph in its filled "done" state, with '
      'no percentage text or credit-cost caption anywhere, and tapping it '
      'still opens the report', (tester) async {
    final pushed = <String>[];
    await tester.pumpWidget(_app(_api(_profile(score: 0.67)), pushed: pushed));
    await tester.pumpAndSettle();

    // The glyph's own filled state is the ONLY signal a score exists now —
    // no "67%" text, no generic "Match" label, no credit-cost caption (a
    // recalc, which the tap still triggers, is free from here on).
    expect(tester.widget<AymaMatchGlyph>(find.byType(AymaMatchGlyph)).filled,
        isTrue);
    expect(find.text('67%'), findsNothing);
    expect(find.text('Match'), findsNothing);
    expect(find.text('12 cr'), findsNothing);

    await tester.tap(find.byType(AymaMatchGlyph));
    await tester.pumpAndSettle();
    expect(pushed, contains('/match/m'));
    expect(find.text('MATCH REPORT'), findsOneWidget);
  });

  testWidgets('an unscored pair still shows the match glyph in its outline '
      '"not done" state, with no label or cost text', (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(tester.widget<AymaMatchGlyph>(find.byType(AymaMatchGlyph)).filled,
        isFalse);
    expect(find.text('Match'), findsNothing);
    expect(find.text('12 cr'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('a capped Run match opens the Upgrade sheet that opens the plans '
      'screen', (tester) async {
    await tester.pumpWidget(_app(_api(
      _profile(),
      compat: {'ok': false, 'usage_capped': true},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AymaMatchGlyph));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text("You're out of credits"), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
    await tester.pumpAndSettle();
    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets('self view is titled "My public profile" and hides the actions',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();

    expect(find.text('My public profile'), findsOneWidget);
    expect(find.byType(AymaChatGlyph), findsNothing);
    expect(find.byType(AymaHeartGlyph), findsNothing);
    // The persistent tab bar still shows even with the action rail hidden.
    expect(find.byTooltip('Profile'), findsOneWidget);
  });

  testWidgets(
      'the You tab page and the self view of PublicProfileScreen render the '
      'identical shared ProfileBody for the same data', (tester) async {
    List<String> bodyTexts() => find
        .descendant(of: find.byType(ProfileBody), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .toList();

    final api = _api(_profile(self: true));
    await tester.pumpWidget(MaterialApp(
      home: MyPublicProfileScreen(myUid: 'her', apiClient: api),
    ));
    await tester.pumpAndSettle();
    final youTab = bodyTexts();
    final youView =
        tester.widget<LivingReportView>(find.byType(LivingReportView));

    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final selfView =
        tester.widget<LivingReportView>(find.byType(LivingReportView));

    expect(find.byType(ProfileBody), findsOneWidget);
    expect(youTab, isNotEmpty);
    expect(bodyTexts(), youTab);
    expect(selfView.reportType, youView.reportType);
    expect(selfView.reportId, youView.reportId);
  });

  testWidgets(
      'self view has no header Ayma action, matching the You tab page',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile(self: true))));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsNothing);
    expect(find.text('Ask Ayma'), findsNothing);
  });

  testWidgets(
      'other-user view has NO header Ayma action — the nav-bar orb already '
      'covers "ask about this profile" (founder: redundant, removed)',
      (tester) async {
    await tester.pumpWidget(_app(_api(_profile())));
    await tester.pumpAndSettle();

    expect(find.text('Dana'), findsWidgets); // on Dana's profile
    expect(find.text('Ask Ayma'), findsNothing);
    expect(find.text('Edit with Ayma'), findsNothing);
  });

  // Regression for the action rail scrolling away: it was `Positioned`
  // *inside* the photo's own `Stack`, which was itself just the first item
  // of the body's `ListView` — so as soon as the user scrolled past the
  // photo, the whole rail scrolled off with it. The founder's report,
  // verbatim: "These should be floating buttons that don't scroll, stacked
  // vertical above the Ayma logo on bottom right." The rail is now mounted
  // in a screen-level `Stack`, a sibling of the scrollable body rather than
  // a descendant of it, so its on-screen position must be identical no
  // matter how far the body is scrolled.
  testWidgets(
      'the floating action rail stays fixed on screen and does not scroll '
      'away with the body', (tester) async {
    // Enough long sections to make the body taller than the viewport, so
    // there is real scrollable overflow to scroll through.
    final pages = [
      for (var i = 0; i < 12; i++)
        {
          'page_type': 'misc',
          'title': 'Section $i',
          'body': 'Paragraph text for section $i. ' * 20,
        },
    ];
    await tester.pumpWidget(_app(_api(_profile(pages: pages))));
    await tester.pumpAndSettle();

    final rail = find.byKey(const Key('profileActionRail'));
    expect(rail, findsOneWidget);
    final rectBeforeScroll = tester.getRect(rail);

    // Confirm there is actually something to scroll through, otherwise this
    // test would pass vacuously.
    final scrollable = find.byType(Scrollable).first;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pumpAndSettle();
    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, greaterThan(before));

    final rectAfterScroll = tester.getRect(rail);
    expect(rectAfterScroll, rectBeforeScroll);

    // Scroll back and confirm it still hasn't moved.
    await tester.drag(scrollable, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(tester.getRect(rail), rectBeforeScroll);
  });

  testWidgets(
      'profile detail renders medium in the carousel, thumbs in the filmstrip '
      '(perf phase 2)', (tester) async {
    AymaPhoto.debugCacheManager =
        _FakeCacheManager(File('test/fixtures/tiny.png'));
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(_app(_api(_profile(
      photos: ['https://x/1.jpg', 'https://x/2.jpg'],
      photosThumb: ['https://x/1t.jpg', 'https://x/2t.jpg'],
      photosMedium: ['https://x/1m.jpg', 'https://x/2m.jpg'],
    ))));
    await tester.pumpAndSettle();

    final headerPhotos = tester
        .widgetList<AymaPhoto>(find.byType(AymaPhoto))
        .where((w) => w.displayWidth == 900 || w.displayWidth == 120)
        .toList();
    expect(headerPhotos, isNotEmpty);
    final carousel =
        headerPhotos.where((w) => w.displayWidth == 900).map((w) => w.url);
    final strip =
        headerPhotos.where((w) => w.displayWidth == 120).map((w) => w.url);
    // Carousel pages: medium variants (PageView pre-builds neighbours, so
    // assert membership, not exact count).
    expect(carousel, contains('https://x/1m.jpg'));
    expect(carousel, isNot(contains('https://x/1.jpg')));
    expect(carousel, isNot(contains('https://x/1t.jpg')));
    // Filmstrip: thumb variants for both photos.
    expect(strip, containsAll(['https://x/1t.jpg', 'https://x/2t.jpg']));
    expect(strip, isNot(contains('https://x/1.jpg')));
    expect(strip, isNot(contains('https://x/2.jpg')));
  });

  testWidgets('profile detail falls back to originals without variant arrays',
      (tester) async {
    AymaPhoto.debugCacheManager =
        _FakeCacheManager(File('test/fixtures/tiny.png'));
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(_app(_api(_profile(
      photos: ['https://x/1.jpg', 'https://x/2.jpg'],
    ))));
    await tester.pumpAndSettle();

    final urls = tester
        .widgetList<AymaPhoto>(find.byType(AymaPhoto))
        .where((w) => w.displayWidth == 900 || w.displayWidth == 120)
        .map((w) => w.url)
        .toList();
    expect(urls, containsAll(['https://x/1.jpg', 'https://x/2.jpg']));
  });
}
