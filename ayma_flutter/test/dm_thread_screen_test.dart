import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart'
    show kComposerBarPadding;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stub ApiClient whose `/profiles/mini` returns [profiles] keyed by uid.
ApiClient _api([Map<String, Map<String, dynamic>> profiles = const {}]) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/profiles/mini') {
        return http.Response(jsonEncode({'profiles': profiles}), 200);
      }
      return http.Response('{}', 200);
    }),
  );
}

class _FakeDm extends DmService {
  _FakeDm(this._msgs, {this.chips = const []})
    : super(
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      );

  final StreamController<List<DmMessage>> _msgs;
  final List<String> sent = [];
  final List<String> blocked = [];
  final List<String> chips;
  final List<File> uploaded = [];
  final List<({String type, String caption})> attachmentsSent = [];

  @override
  Stream<List<DmMessage>> watchMessages(String threadId) => _msgs.stream;

  @override
  Future<List<String>> icebreakers(String threadId) async => chips;

  @override
  Future<void> block(String otherUid) async => blocked.add(otherUid);

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<void> sendText(String threadId, String text) async {
    sent.add(text);
    _msgs.add([
      DmMessage(
        id: 'x',
        senderUid: 'me',
        type: 'text',
        body: text,
        createdAt: DateTime.now(),
      ),
    ]);
  }

  @override
  Future<DmAttachment> uploadAttachment(
    File file, {
    required String threadId,
  }) async {
    uploaded.add(file);
    return const DmAttachment(
      storagePath: 'uploads/me/dm/a__me/1.jpg',
      downloadUrl: 'https://example.invalid/1.jpg',
      contentType: 'image/jpeg',
      sizeBytes: 1234,
      name: '1.jpg',
    );
  }

  @override
  Future<void> sendAttachment(
    String threadId, {
    required String type,
    required DmAttachment attachment,
    String caption = '',
  }) async {
    attachmentsSent.add((type: type, caption: caption));
  }
}

/// The Padding that wraps the DM composer bar — identified by the shared
/// constant it must use ([kComposerBarPadding], the Ayma chat's own value).
Finder _composerPadding() => find.byWidgetPredicate(
  (w) => w is Padding && w.padding == kComposerBarPadding,
);

void main() {
  // The icebreaker dismissal persists via shared_preferences (see
  // `DmThreadScreen.icebreakersDismissedKey`) — give every test a clean,
  // in-memory store.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'the composer uses the shared Ayma-chat padding and adds no extra '
    'bottom safe-area inset (the nav bar below already pads that in)',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(ctrl);
      const barHeight = 84.0; // stand-in for NavBarShell's AymaTabBar
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              // A device bottom inset (gesture bar) — NavBarShell's AymaTabBar
              // consumes it itself, so the DM screen must NOT pad it in again.
              data: MediaQuery.of(context)
                  .copyWith(padding: const EdgeInsets.only(bottom: 40)),
              child: Column(
                children: [
                  Expanded(
                    child: DmThreadScreen(
                      threadId: 'a__me',
                      dmService: dm,
                      apiClient: _api(),
                    ),
                  ),
                  const SizedBox(height: barHeight),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      ctrl.add(const []);
      await tester.pumpAndSettle();

      // Exactly one composer padding, using the shared constant…
      expect(_composerPadding(), findsOneWidget);
      // …and its bottom edge sits flush against the nav bar below — the same
      // treatment as the Ayma chat, not floated 40px higher by a doubled inset.
      expect(
        tester.getBottomLeft(_composerPadding()).dy,
        moreOrLessEquals(1000 - barHeight),
      );
    },
  );

  testWidgets('the newest message stays fully visible above the composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: DmThreadScreen(
          threadId: 'a__me',
          dmService: dm,
          apiClient: _api(),
        ),
      ),
    );
    await tester.pump();

    // Enough messages to overflow the viewport by a long way.
    ctrl.add([
      for (var i = 0; i < 40; i++)
        DmMessage(
          id: 'm$i',
          senderUid: i.isEven ? 'a' : 'me',
          type: 'text',
          body: 'message $i',
          createdAt: DateTime.now(),
        ),
      DmMessage(
        id: 'newest',
        senderUid: 'a',
        type: 'text',
        body: 'the newest message',
        createdAt: DateTime.now(),
      ),
    ]);
    await tester.pumpAndSettle();

    // The list is pinned to the newest message, and its bubble bottoms out
    // above the composer instead of sliding half-hidden behind it.
    final newest = find.text('the newest message');
    expect(newest, findsOneWidget);
    expect(
      tester.getBottomLeft(newest).dy,
      lessThan(tester.getTopLeft(_composerPadding()).dy),
    );
  });

  testWidgets(
    'the icebreaker close button hides the suggestions and the dismissal '
    'survives rebuilding the screen — but only for that thread',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(ctrl, chips: ['Ask about the dog park']);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(
            threadId: 'a__me',
            dmService: dm,
            apiClient: _api(),
          ),
        ),
      );
      await tester.pump();
      ctrl.add(const []);
      await tester.pumpAndSettle();

      expect(find.text('Things to talk about'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide suggestions'));
      await tester.pumpAndSettle();
      expect(find.text('Things to talk about'), findsNothing);
      expect(find.text('Ask about the dog park'), findsNothing);

      // A brand-new screen for the same thread (reopen / app restart): the
      // service still offers chips, but the persisted dismissal wins. Tear the
      // old tree down first — otherwise pumpWidget reuses the same State and
      // initState (the dismissal read) never re-runs.
      await tester.pumpWidget(const SizedBox());
      final ctrl2 = StreamController<List<DmMessage>>.broadcast();
      final dm2 = _FakeDm(ctrl2, chips: ['Ask about the dog park']);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(
            threadId: 'a__me',
            dmService: dm2,
            apiClient: _api(),
          ),
        ),
      );
      await tester.pump();
      ctrl2.add(const []);
      await tester.pumpAndSettle();
      expect(find.text('Things to talk about'), findsNothing);

      // A different thread is untouched by that dismissal.
      await tester.pumpWidget(const SizedBox());
      final ctrl3 = StreamController<List<DmMessage>>.broadcast();
      final dm3 = _FakeDm(ctrl3, chips: ['Ask about the dog park']);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(
            threadId: 'b__me',
            dmService: dm3,
            apiClient: _api(),
          ),
        ),
      );
      await tester.pump();
      ctrl3.add(const []);
      await tester.pumpAndSettle();
      expect(find.text('Things to talk about'), findsOneWidget);
    },
  );

  testWidgets(
    'a shared_report message renders as an in-app card (no raw link, '
    'placeholder on image error) and opens the report natively',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(ctrl);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => DmThreadScreen(
              threadId: 'a__me',
              dmService: dm,
              apiClient: _api(),
            ),
          ),
          GoRoute(
            path: '/s/:token',
            builder: (_, state) =>
                Text('opened ${state.pathParameters['token']}'),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();

      ctrl.add([
        DmMessage.fromData('1', {
          'sender_uid': 'a',
          'type': 'shared_report',
          'body': '',
          'report_share': {
            'token': 'tok123',
            'title': 'Appearance',
            'summary': 'Score: 7',
            'card_url': 'http://127.0.0.1:1/s/tok123/card.png',
          },
        }),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Score: 7'), findsOneWidget);
      expect(find.textContaining('justabot.info'), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);

      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('opened tok123'), findsOneWidget);
    },
  );

  testWidgets('renders bubbles by type and sends text', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: DmThreadScreen(
          threadId: 'a__me',
          dmService: dm,
          apiClient: _api(),
        ),
      ),
    );
    await tester.pump();

    ctrl.add([
      DmMessage(
        id: '1',
        senderUid: 'a',
        type: 'text',
        body: 'hey',
        createdAt: DateTime.now(),
      ),
      DmMessage(
        id: '2',
        senderUid: 'a',
        type: 'shared_profile',
        body: 'c',
        createdAt: DateTime.now(),
      ),
      DmMessage(
        id: '3',
        senderUid: 'me',
        type: 'photo',
        body: 'uploads/me/p.jpg',
        createdAt: DateTime.now(),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('hey'), findsOneWidget);
    expect(find.text('👤 Shared a profile'), findsOneWidget);
    expect(find.text('📷 Photo'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'yo');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(dm.sent, ['yo']);
    expect(find.text('yo'), findsOneWidget);
  });

  testWidgets(
    'renders an image attachment as a tappable thumbnail with caption',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(ctrl);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(threadId: 'a__me', dmService: dm),
        ),
      );
      await tester.pump();
      ctrl.add([
        DmMessage(
          id: 'i1',
          senderUid: 'a',
          type: 'image',
          body: 'sunset',
          createdAt: DateTime.now(),
          attachmentUrl: 'https://example.invalid/i1.jpg',
          attachmentPath: 'uploads/a/dm/a__me/i1.jpg',
          mime: 'image/jpeg',
          fileName: 'i1.jpg',
          size: 4096,
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsWidgets);
      expect(find.text('sunset'), findsOneWidget);

      // Tap the thumbnail -> full-screen viewer with close, share and
      // download actions.
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);

      // And the close button returns to the thread.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.share_outlined), findsNothing);
      expect(find.text('sunset'), findsOneWidget);
    },
  );

  testWidgets('renders a file attachment as a name + size row', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: DmThreadScreen(threadId: 'a__me', dmService: dm),
      ),
    );
    await tester.pump();
    ctrl.add([
      DmMessage(
        id: 'f1',
        senderUid: 'me',
        type: 'file',
        body: '',
        createdAt: DateTime.now(),
        attachmentUrl: 'https://example.invalid/report.pdf',
        attachmentPath: 'uploads/me/dm/a__me/report.pdf',
        mime: 'application/pdf',
        fileName: 'report.pdf',
        size: 2 * 1024 * 1024,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('2.0 MB'), findsOneWidget);
  });

  testWidgets('the attach button opens the Photo / Camera / File sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: DmThreadScreen(threadId: 'a__me', dmService: dm),
      ),
    );
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
  });

  testWidgets(
    'tapping a conversation-starter fills the composer and it stays',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(ctrl, chips: ['What trail do you run?']);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(
            threadId: 'a__me',
            dmService: dm,
            apiClient: _api(),
          ),
        ),
      );
      await tester.pump();
      ctrl.add(const []);
      await tester.pumpAndSettle();

      expect(find.text('Things to talk about'), findsOneWidget);
      await tester.tap(find.text('What trail do you run?'));
      await tester.pumpAndSettle();

      // Filled the composer for editing — and stays available as common ground.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'What trail do you run?',
      );
      expect(find.text('Things to talk about'), findsOneWidget);
    },
  );

  testWidgets('block & report confirms then calls block and pops', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DmThreadScreen(
                    threadId: 'a__me',
                    dmService: dm,
                    apiClient: _api(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block & report'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();

    expect(dm.blocked, ['a']);
    expect(find.byType(DmThreadScreen), findsNothing);
  });

  testWidgets(
    'a flagged message shows the red moderation treatment, an unflagged one does not',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(ctrl);
      await tester.pumpWidget(
        MaterialApp(
          home: DmThreadScreen(threadId: 'a__me', dmService: dm),
        ),
      );
      await tester.pump();

      ctrl.add([
        DmMessage(
          id: '1',
          senderUid: 'a',
          type: 'text',
          body: 'hey there',
          createdAt: DateTime.now(),
        ),
        DmMessage(
          id: '2',
          senderUid: 'a',
          type: 'text',
          body: 'nasty stuff',
          createdAt: DateTime.now(),
          moderated: true,
        ),
      ]);
      await tester.pumpAndSettle();

      // Flagging is an annotation, never a redaction — the full text renders.
      expect(find.text('hey there'), findsOneWidget);
      expect(find.text('nasty stuff'), findsOneWidget);

      // Only the flagged bubble gets the red "Flagged for review" treatment.
      expect(find.text('Flagged for review'), findsOneWidget);
      expect(find.byIcon(Icons.flag_rounded), findsOneWidget);
    },
  );

  testWidgets('the header shows the other person, not "Conversation"', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: DmThreadScreen(
          threadId: 'a__me',
          dmService: dm,
          apiClient: _api({
            'a': {'name': 'Priya Nair', 'photo': '', 'online': true},
          }),
        ),
      ),
    );
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    expect(find.text('Priya Nair'), findsOneWidget);
    expect(find.text('Conversation'), findsNothing);
  });

  testWidgets('tapping the header opens the other person\'s public profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    final pushed = <String>[];

    final router = GoRouter(
      initialLocation: '/dm/a__me',
      routes: [
        GoRoute(
          path: '/dm/:threadId',
          builder: (_, __) => DmThreadScreen(
            threadId: 'a__me',
            dmService: dm,
            apiClient: _api({
              'a': {'name': 'Priya Nair', 'photo': '', 'online': true},
            }),
          ),
        ),
        GoRoute(
          path: '/profile/user/:uid',
          builder: (_, s) {
            pushed.add(s.pathParameters['uid']!);
            return const Scaffold(body: Text('PROFILE PAGE'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Priya Nair'));
    await tester.pumpAndSettle();

    expect(pushed, ['a']);
    expect(find.text('PROFILE PAGE'), findsOneWidget);
  });
}
