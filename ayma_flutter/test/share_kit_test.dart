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
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/share_kit.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/ayma_share_sheet.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
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

ShareTarget _conversationTarget() => ShareTargets.conversation(
      threadId: 't_u1_u2',
      otherUid: 'u2',
      otherName: 'Dillu',
      otherPhoto: 'https://example.com/dillu.jpg',
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

  testWidgets('profile sheet shows both options with the founder labels and gray wings mark',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_sheetHost(_profileTarget(), AymaShare(api: api)));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Send to Ayma'), findsOneWidget);
    expect(find.text('Send externally'), findsOneWidget);
    expect(find.text('Dillu'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.byType(AymaWingsIcon), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
  });

  testWidgets('profile sheet geometry matches Jobs-grade polish spec',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_sheetHost(_profileTarget(), AymaShare(api: api)));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    // Defect 1: Header horizontal padding 16 -> 20 (left and right)
    final headerPaddingFinder = find.ancestor(
      of: find.text('Dillu'),
      matching: find.byType(Padding),
    ).first;
    final headerPadding = tester.widget<Padding>(headerPaddingFinder);
    expect(headerPadding.padding, const EdgeInsets.fromLTRB(20, 4, 20, 8));

    // Defect 2: ListTile contentPadding start 20, end 24 on both options
    final aymaTile = tester.widget<ListTile>(find.byKey(const ValueKey('shareSendToAyma')));
    expect(
      aymaTile.contentPadding,
      const EdgeInsetsDirectional.only(start: 20, end: 24),
    );
    final externalTile = tester.widget<ListTile>(find.byKey(const ValueKey('shareSendExternally')));
    expect(
      externalTile.contentPadding,
      const EdgeInsetsDirectional.only(start: 20, end: 24),
    );

    // Defect 3: 24 of space below the last row inside SafeArea
    final column = tester.widget<Column>(find.ancestor(
      of: find.byKey(const ValueKey('shareSendToAyma')),
      matching: find.byType(Column),
    ).first);
    final lastChild = column.children.last;
    expect(lastChild, isA<SizedBox>());
    expect((lastChild as SizedBox).height, 24);

    // Defect 4: Gap 2 between name and type label, name height 1.25
    final nameText = tester.widget<Text>(find.text('Dillu'));
    expect(nameText.style?.height, 1.25);
    final textColumn = tester.widget<Column>(find.ancestor(
      of: find.text('Dillu'),
      matching: find.byType(Column),
    ).first);
    expect(textColumn.children[1], isA<SizedBox>());
    expect((textColumn.children[1] as SizedBox).height, 2);
  });

  testWidgets('story sheet (one-row variant) has 20 edges and 24 bottom space',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_sheetHost(
      ShareTargets.story(uid: 'u1', imageUrl: 'https://example.com/s.jpg'),
      AymaShare(api: api),
    ));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    final headerPaddingFinder = find.ancestor(
      of: find.text('Your Story'),
      matching: find.byType(Padding),
    ).first;
    final headerPadding = tester.widget<Padding>(headerPaddingFinder);
    expect(headerPadding.padding, const EdgeInsets.fromLTRB(20, 4, 20, 8));

    final aymaTile = tester.widget<ListTile>(find.byKey(const ValueKey('shareSendToAyma')));
    expect(
      aymaTile.contentPadding,
      const EdgeInsetsDirectional.only(start: 20, end: 24),
    );

    final column = tester.widget<Column>(find.ancestor(
      of: find.byKey(const ValueKey('shareSendToAyma')),
      matching: find.byType(Column),
    ).first);
    final lastChild = column.children.last;
    expect(lastChild, isA<SizedBox>());
    expect((lastChild as SizedBox).height, 24);
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

  testWidgets('conversation sheet is Ayma-only — only Send to Ayma, naming the partner',
      (tester) async {
    await tester.pumpWidget(
        _sheetHost(_conversationTarget(), AymaShare(api: _FakeApi())));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Send to Ayma'), findsOneWidget);
    // A human chat never leaves the app — no external option, same as Story.
    expect(find.text('Send externally'), findsNothing);
    expect(find.text('Your chat with Dillu'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
  });

  testWidgets(
      'conversation Send to Ayma pushes a draft_about by thread reference',
      (tester) async {
    await tester.pumpWidget(
        _sheetHost(_conversationTarget(), AymaShare(api: _FakeApi())));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send to Ayma'));
    await tester.pumpAndSettle();
    final k = ChatInbox.instance.take();
    expect(k?.kind, 'draft_about');
    expect(k?.shareKind, 'conversation');
    // By reference: the thread id, never inline message content.
    expect(k?.refId, 't_u1_u2');
    expect(k?.targetUid, 'u2');
    expect(k?.label, 'Dillu');
    expect(k?.photoUrl, 'https://example.com/dillu.jpg');
  });

  test('a conversation target refuses any external share outright', () async {
    final api = _FakeApi();
    final share = AymaShare(api: api);
    final target = _conversationTarget();
    await expectLater(
      share.shareExternally(_FakeContext(), target),
      throwsA(isA<ShareKitException>()),
    );
    expect(api.linkShareCalls, 0);
  });

  testWidgets('Send to Ayma pushes a draft-about kickoff with the photo',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_sheetHost(_profileTarget(), AymaShare(api: api)));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send to Ayma'));
    await tester.pumpAndSettle();
    final k = ChatInbox.instance.take();
    expect(k?.kind, 'draft_about');
    expect(k?.shareKind, 'profile');
    expect(k?.targetUid, 'u2');
    expect(k?.label, 'Dillu');
    expect(k?.photoUrl, 'https://example.com/dillu.jpg');
  });

  group('the chat card', () {
    Future<void> pumpChat(
      WidgetTester tester, {
      required ChatKickoff kickoff,
      bool sendStaged = true,
      String? text,
      List<Map<String, dynamic>>? capturedCalls,
    }) async {
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
          if (capturedCalls != null) {
            capturedCalls.add(jsonDecode(request.body) as Map<String, dynamic>);
          }
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
          GoRoute(
            path: '/deep-dive/:id',
            builder: (_, state) =>
                Scaffold(body: Text('DEEP DIVE PAGE ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/match/:id',
            builder: (_, state) =>
                Scaffold(body: Text('MATCH PAGE ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/appearance/:id',
            builder: (_, state) =>
                Scaffold(body: Text('APPEARANCE PAGE ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/dm/:id',
            builder: (_, state) =>
                Scaffold(body: Text('DM PAGE ${state.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      ChatInbox.instance.push(kickoff);
      await tester.pumpAndSettle();
      if (sendStaged) {
        if (text != null && text.isNotEmpty) {
          await tester.enterText(find.byType(TextField).last, text);
          await tester.pump();
        }
        await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
        await tester.pumpAndSettle();
      }
    }

    testWidgets(
        'Send to Ayma stages the card above the composer — composer empty, nothing sent, card tappable',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      await pumpChat(
        tester,
        kickoff: _profileTarget().aymaKickoff(),
        sendStaged: false,
        capturedCalls: captured,
      );
      // Staged card is visible above composer with reply-style layout.
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      expect(find.text('Dillu'), findsOneWidget);
      expect(find.text('PROFILE · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsOneWidget);
      // No pin chip anywhere.
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

      // Composer is empty and nothing is in transcript.
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.controller?.text ?? '', isEmpty);
      expect(find.textContaining("Let's talk about"), findsNothing);
      expect(captured, isEmpty);

      // Tapping the staged card opens the profile.
      await tester.tap(find.text('PROFILE · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('PROFILE PAGE u2'), findsOneWidget);
    });

    testWidgets(
        'Send to Ayma for story stages the story card with image and no pin chip',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.story(
          uid: 'u1',
          imageUrl: 'https://example.com/story.jpg',
        ).aymaKickoff(),
        sendStaged: false,
      );
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      expect(find.text('Your Story'), findsOneWidget);
      expect(find.text('STORY · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

      // Tapping opens story page.
      await tester.tap(find.text('STORY · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('STORY PAGE'), findsOneWidget);
    });

    testWidgets(
        'Send to Ayma for web research stages the card, not old label chip or pin chip',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.webResearch(
          reportId: 'dd1',
          subjectUid: 'u3',
          subjectName: 'Jordan',
          subjectImage: 'https://example.com/jordan.jpg',
        ).aymaKickoff(),
        sendStaged: false,
      );
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      expect(find.text('Web research on Jordan'), findsOneWidget);
      expect(find.text('WEB FINDING · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

      // Tapping opens web research page.
      await tester.tap(find.text('WEB FINDING · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('DEEP DIVE PAGE dd1'), findsOneWidget);
    });

    testWidgets(
        'Send to Ayma for match report stages the match card',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.matchReport(
          matchId: 'm1',
          otherUid: 'u4',
          otherName: 'Taylor',
          otherPhoto: 'https://example.com/taylor.jpg',
        ).aymaKickoff(),
        sendStaged: false,
      );
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      expect(find.text('Taylor · match report'), findsOneWidget);
      expect(find.text('MATCH REPORT · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

      // Tapping opens match report page.
      await tester.tap(find.text('MATCH REPORT · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('MATCH PAGE m1'), findsOneWidget);
    });

    testWidgets(
        'Send to Ayma for appearance report stages the appearance card',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: ShareTargets.appearance(
          uid: 'u5',
          title: 'Your appearance report',
          photoUrl: 'https://example.com/app.jpg',
        ).aymaKickoff(),
        sendStaged: false,
      );
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      expect(find.text('Your appearance report'), findsOneWidget);
      expect(find.text('APPEARANCE REPORT · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

      // Tapping opens appearance page.
      await tester.tap(find.text('APPEARANCE REPORT · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('APPEARANCE PAGE u5'), findsOneWidget);
    });

    testWidgets(
        'Send to Ayma for a chat stages the chat card; tapping it opens the thread',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: _conversationTarget().aymaKickoff(),
        sendStaged: false,
      );
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      expect(find.text('Your chat with Dillu'), findsOneWidget);
      expect(find.text('CHAT · TAP TO OPEN'), findsOneWidget);
      expect(find.byType(AymaPhoto), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

      // Tapping the staged card opens the DM thread (founder-approved card).
      await tester.tap(find.text('CHAT · TAP TO OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('DM PAGE t_u1_u2'), findsOneWidget);
    });

    testWidgets(
        'sending a staged chat carries the reference (thread id), never the messages',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      await pumpChat(
        tester,
        kickoff: _conversationTarget().aymaKickoff(),
        sendStaged: false,
        capturedCalls: captured,
      );
      // Tap send with no typed opener — no canned message (founder Nov 9).
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(captured, hasLength(1));
      // The reference rides (Ayma pulls the messages herself with it)…
      expect(captured.single['shared_kind'], 'conversation');
      expect(captured.single['shared_ref_id'], 't_u1_u2');
      // …and the card rides for rendering, by reference too.
      expect(captured.single['shared_card_kind'], 'conversation');
      expect(captured.single['shared_card_ref_id'], 't_u1_u2');
      // Never a canned opener.
      expect(find.textContaining("Here's my conversation"), findsNothing);
    });

    testWidgets(
        'pending share kickoff survives tab-switch pageContext push',
        (tester) async {
      // Push a share kickoff.
      ChatInbox.instance.push(_profileTarget().aymaKickoff());
      // A tab-switch pageContext push arrives.
      ChatInbox.instance.push(ChatKickoff.pageContext(
        const ScreenContext(screen: 'explore'),
      ));
      // The pending kickoff is still the share kickoff.
      expect(ChatInbox.instance.pending.value?.kind, 'draft_about');
      expect(ChatInbox.instance.pending.value?.shareKind, 'profile');
    });

    testWidgets(
        'plain tab switch with no share in flight pushes pageContext',
        (tester) async {
      ChatInbox.instance.push(ChatKickoff.pageContext(
        const ScreenContext(screen: 'explore'),
      ));
      expect(ChatInbox.instance.pending.value?.kind, 'page_context');
      expect(ChatInbox.instance.pending.value?.screenContext?.label, 'Explore');
    });

    testWidgets(
        'tap send with card staged and no text sends card alone with no canned opener',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      await pumpChat(
        tester,
        kickoff: _profileTarget().aymaKickoff(),
        sendStaged: false,
        capturedCalls: captured,
      );
      // Tap send with no text.
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      // Card is in transcript, but no text bubble or canned opener.
      expect(find.text('PROFILE · TAP TO OPEN'), findsOneWidget);
      expect(find.textContaining("Let's talk about"), findsNothing);
      expect(captured, hasLength(1));
      expect(captured.single['viewing_profile_uid'], 'u2');
      expect(captured.single['message'], '[shared profile]');
    });

    testWidgets(
        'type own text and tap send sends card and text together',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      await pumpChat(
        tester,
        kickoff: _profileTarget().aymaKickoff(),
        sendStaged: true,
        text: 'What is your honest read on them?',
        capturedCalls: captured,
      );

      // Both card and user's typed message appear together.
      expect(find.text('PROFILE · TAP TO OPEN'), findsOneWidget);
      expect(find.text('What is your honest read on them?'), findsOneWidget);
      expect(captured, hasLength(1));
      expect(captured.single['viewing_profile_uid'], 'u2');
      expect(captured.single['message'], 'What is your honest read on them?');
    });

    testWidgets('clearing the staged chip removes attachment without sending',
        (tester) async {
      await pumpChat(
        tester,
        kickoff: _profileTarget().aymaKickoff(),
        sendStaged: false,
      );
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('clearSharedDraft')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stagedSharedChip')), findsNothing);
      expect(find.text('PROFILE · TAP TO OPEN'), findsNothing);
    });

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
