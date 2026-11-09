// The reusable share kit (founder, 2026-11-08): one sheet, two options
// ("Send to Ayma" / "Send externally") for every target kind; the
// reply-style card (never a pin) in the Ayma chat; Ayma-only enforcement
// for Your Story; the profile placements; the /p/ deep-link route.
import 'dart:convert';

import 'package:ayma_flutter/models/share_link.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/screens/shared_profile_link_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/share_kit.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/ayma_share_sheet.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:share_plus/share_plus.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  int linkShareCalls = 0;

  @override
  Future<LinkShare> createLinkShare(String kind, String targetId) async {
    linkShareCalls++;
    return const LinkShare(
      token: 'TOK',
      url: 'https://justabot.info/p/TOK',
      title: 'Dillu on Ayma',
      summary: 'Dillu · 30 · San Jose',
    );
  }

  @override
  Future<PageShareTarget> pageShareTarget(String token) async =>
      const PageShareTarget(
        kind: 'profile',
        targetId: 'u2',
        title: 'Dillu on Ayma',
        summary: 'Dillu · 30 · San Jose',
      );
}

ShareTarget _profileTarget() => ShareTargets.profile(
      uid: 'u2',
      name: 'Dillu',
      photoUrl: 'https://example.com/dillu.jpg',
    );

/// A host page at '/' (the shell path) with a button that opens the kit
/// sheet for [target] through the injected [share].
Widget _sheetHost(ShareTarget target, AymaShare share) {
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (ctx, _) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showAymaShareSheet(ctx, target, share: share),
            child: const Text('open sheet'),
          ),
        ),
      ),
    ),
  ]);
  return MaterialApp.router(routerConfig: router);
}

void main() {
  tearDown(() => ChatInbox.instance.take());
  tearDown(PendingPageShare.resetForTest);

  testWidgets('profile sheet shows both options with the founder labels',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_sheetHost(_profileTarget(), AymaShare(api: api)));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Send to Ayma'), findsOneWidget);
    expect(find.text('Send externally'), findsOneWidget);
    expect(find.text('Dillu'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('Send externally composes the /p/ link for the profile',
      (tester) async {
    final api = _FakeApi();
    ShareParams? captured;
    final share = AymaShare(
      api: api,
      systemShare: (p) async => captured = p,
    );
    await tester.pumpWidget(_sheetHost(_profileTarget(), share));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send externally'));
    await tester.pumpAndSettle();
    expect(api.linkShareCalls, 1);
    expect(captured?.text, 'Dillu on Ayma — Dillu · 30 · San Jose\n'
        'https://justabot.info/p/TOK');
    expect(captured?.subject, 'Dillu on Ayma');
  });

  testWidgets('Send to Ayma pushes a talk-about kickoff with the photo',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_sheetHost(_profileTarget(), AymaShare(api: api)));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send to Ayma'));
    await tester.pumpAndSettle();
    final k = ChatInbox.instance.take();
    expect(k?.kind, 'talk_about');
    expect(k?.shareKind, 'profile');
    expect(k?.targetUid, 'u2');
    expect(k?.label, 'Dillu');
    expect(k?.photoUrl, 'https://example.com/dillu.jpg');
  });

  group('the chat card', () {
    Future<void> pumpChat(WidgetTester tester,
        {required ChatKickoff kickoff}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final mockHttp = MockClient((request) async {
        if (request.url.path == '/chat/history') {
          return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}),
            200,
            headers: _jsonUtf8,
          );
        }
        if (request.url.path == '/chat/stream') {
          return http.Response('stream unavailable', 500);
        }
        if (request.url.path == '/chat') {
          return http.Response(
            jsonEncode({'reply': "Here's my read.", 'usage_capped': false}),
            200,
            headers: _jsonUtf8,
          );
        }
        return http.Response('{}', 200, headers: _jsonUtf8);
      });
      final api = ApiClient(
        httpClient: mockHttp,
        auth: MockFirebaseAuth(signedIn: true),
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => ChatScreen(apiClient: api)),
          GoRoute(
            path: '/profile/user/:uid',
            builder: (_, state) =>
                Scaffold(body: Text('PROFILE PAGE ${state.pathParameters['uid']}')),
          ),
          GoRoute(
            path: '/profile/wiki',
            builder: (_, __) => const Scaffold(body: Text('STORY PAGE')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      ChatInbox.instance.push(kickoff);
      await tester.pumpAndSettle();
    }

    testWidgets('a shared profile renders as a reply card with its photo, '
        'never a pin, and tapping it opens the profile', (tester) async {
      await pumpChat(tester, kickoff: _profileTarget().aymaKickoff());
      expect(find.text('Dillu'), findsWidgets);
      expect(find.text('PROFILE · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsWidgets);
      // No pin chip for a share.
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
      await tester.tap(find.text('PROFILE · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('PROFILE PAGE u2'), findsOneWidget);
    });

    testWidgets('a shared target with no image renders the card without one',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.profile(uid: 'u9', name: 'NoPhoto').aymaKickoff(),
      );
      expect(find.text('PROFILE · TAP TO OPEN'), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsWidgets);
      expect(find.byType(AymaPhoto), findsNothing);
    });

    testWidgets('a shared story renders its card with its image',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.story(
          uid: 'u1',
          imageUrl: 'https://example.com/story.jpg',
        ).aymaKickoff(),
      );
      expect(find.text('Your Story'), findsWidgets);
      expect(find.text('STORY · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsWidgets);
      await tester.tap(find.text('STORY · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('STORY PAGE'), findsOneWidget);
    });

    testWidgets('a shared appearance report renders its card',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.appearance(
          uid: 'u1',
          title: 'Your appearance report',
          photoUrl: 'https://example.com/card.jpg',
        ).aymaKickoff(),
      );
      expect(find.text('APPEARANCE REPORT · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsWidgets);
    });
  });

  group('story is Ayma-only, enforced in the kit', () {
    testWidgets('the story sheet has no external option', (tester) async {
      final share = AymaShare(api: _FakeApi());
      await tester.pumpWidget(_sheetHost(
        ShareTargets.story(uid: 'u1', imageUrl: 'https://example.com/s.jpg'),
        share,
      ));
      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      expect(find.text('Send to Ayma'), findsOneWidget);
      expect(find.text('Send externally'), findsNothing);
    });

    test('composing an external share for story refuses outright', () async {
      final api = _FakeApi();
      final share = AymaShare(api: api);
      final target = ShareTargets.story(uid: 'u1');
      await expectLater(
        share.shareExternally(_FakeContext(), target),
        throwsA(isA<ShareKitException>()),
      );
      await expectLater(
        share.createExternalLink(target),
        throwsA(isA<ShareKitException>()),
      );
      // Nothing was created: no link call ever happened.
      expect(api.linkShareCalls, 0);
    });
  });

  test('appearance external runs the page-provided card share', () async {
    var ran = false;
    final target = ShareTargets.appearance(
      uid: 'u1',
      title: 'Your appearance report',
      photoUrl: 'https://example.com/card.jpg',
      externalOverride: (_) async => ran = true,
    );
    await AymaShare(api: _FakeApi()).shareExternally(_FakeContext(), target);
    expect(ran, isTrue);
  });

  group('placements', () {
    MockClient profileBackend(List<String> seen) =>
        MockClient((request) async {
          seen.add(request.url.path);
          if (request.url.path == '/explore/profile/u2' ||
              request.url.path == '/explore/profile/u1') {
            final self = request.url.path.endsWith('u1');
            return http.Response(
              jsonEncode({
                'uid': self ? 'u1' : 'u2',
                'self': self,
                'blocked': false,
                'name': self ? 'Sam' : 'Dillu',
                'age': 30,
                'location': 'San Jose',
                'photos': ['https://example.com/p1.jpg'],
                'pages': <dynamic>[],
                'liked': false,
                'score': null,
                'thread_id': null,
                'has_chatted': false,
              }),
              200,
              headers: _jsonUtf8,
            );
          }
          return http.Response(
            jsonEncode({
              'title': 'Story',
              'sections': <dynamic>[],
              'meta': {'owner_uid': 'u1', 'viewer_can_edit': true},
            }),
            200,
            headers: _jsonUtf8,
          );
        });

    testWidgets('the profile page header carries the share button',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = ApiClient(
        httpClient: profileBackend([]),
        auth: MockFirebaseAuth(signedIn: true),
      );
      final router = GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => PublicProfileScreen(uid: 'u2', api: api),
        ),
      ]);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profileShareButton')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('profileShareButton')));
      await tester.pumpAndSettle();
      expect(find.text('Send to Ayma'), findsOneWidget);
      expect(find.text('Send externally'), findsOneWidget);
    });

    testWidgets('My public profile: share replaces the header add-photo, '
        'the strip add tile stays', (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = ApiClient(
        httpClient: profileBackend([]),
        auth: MockFirebaseAuth(signedIn: true),
      );
      await tester.pumpWidget(MaterialApp(
        home: MyPublicProfileScreen(apiClient: api, myUid: 'u1'),
      ));
      await tester.pumpAndSettle();
      // Header: pencil + share, no add-photo.
      final appBar = find.byType(AppBar);
      expect(appBar, findsOneWidget);
      expect(find.byKey(const ValueKey('myProfileShareButton')), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(
        find.descendant(
            of: appBar, matching: find.byIcon(Icons.add_a_photo_outlined)),
        findsNothing,
      );
      // The photo strip's add tile is still the way to add photos here.
      expect(find.byIcon(Icons.add_a_photo_outlined), findsWidgets);
      // And the share button opens the kit sheet for the own profile.
      await tester.tap(find.byKey(const ValueKey('myProfileShareButton')));
      await tester.pumpAndSettle();
      expect(find.text('Send to Ayma'), findsOneWidget);
      expect(find.text('Send externally'), findsOneWidget);
      expect(find.text('Sam'), findsWidgets);
    });
  });

  group('the /p/ deep link', () {
    test('a profile target resolves to the profile route', () {
      expect(
        const PageShareTarget(
          kind: 'profile',
          targetId: 'u2',
          title: 't',
          summary: 's',
        ).route,
        '/profile/user/u2',
      );
      expect(
        const PageShareTarget(
          kind: 'mystery',
          targetId: 'x',
          title: 't',
          summary: 's',
        ).route,
        '',
      );
    });

    testWidgets('signed out, the link screen shows the teaser and stashes '
        'the route for after sign-in', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SharedProfileLinkScreen(token: 'TOK', api: _FakeApi()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Dillu on Ayma'), findsOneWidget);
      expect(find.text('Sign in to see this profile'), findsOneWidget);
      expect(PendingPageShare.take(), '/profile/user/u2');
    });
  });
}

class _FakeContext extends Fake implements BuildContext {}
