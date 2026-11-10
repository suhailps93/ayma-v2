import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/freshness_indicator.dart';
import 'package:ayma_flutter/widgets/message_timestamp.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart'
    show kComposerBarPadding;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  _FakeDm(this._msgs,
      {DmAssist Function(List<DmMessage>)? assist, this.freshCtrl})
    : _assistFn = assist,
      super(
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      );

  final StreamController<List<DmMessage>> _msgs;
  final StreamController<FreshData<List<DmMessage>>>? freshCtrl;
  final List<String> sent = [];
  int failNextSends = 0;
  final List<String> blocked = [];

  /// Produces the coaching response for a given message tail; null → empty.
  final DmAssist Function(List<DmMessage>)? _assistFn;

  /// The message tails the screen asked [assist] about, in order.
  final List<List<DmMessage>> assistCalls = [];
  final List<File> uploaded = [];
  final List<({Uint8List bytes, String mime})> insertedUploads = [];
  final List<({String type, String caption})> attachmentsSent = [];

  @override
  Stream<List<DmMessage>> watchMessages(String threadId,
      {int limit = 30}) =>
      _msgs.stream;

  @override
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) async {
    assistCalls.add(messages);
    return _assistFn?.call(messages) ?? DmAssist.empty;
  }

  @override
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(String threadId,
          {int limit = 30}) =>
      freshCtrl?.stream ?? _msgs.stream.map((m) => FreshData(data: m));

  @override
  Future<void> block(String otherUid) async => blocked.add(otherUid);

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<void> sendText(String threadId, String text) async {
    if (failNextSends > 0) {
      failNextSends--;
      throw StateError('refused');
    }
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
  Future<DmAttachment> uploadInsertedAttachment(
    Uint8List bytes, {
    required String threadId,
    required String mime,
  }) async {
    insertedUploads.add((bytes: bytes, mime: mime));
    return const DmAttachment(
      storagePath: 'uploads/me/dm/a__me/inserted_1.gif',
      downloadUrl: 'https://example.invalid/inserted_1.gif',
      contentType: 'image/gif',
      sizeBytes: 3,
      name: 'inserted_1.gif',
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
    'opener-mode chips render on a brand-new (empty) thread, with no tip',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        // Opener for an empty tail; a coach reply only once messages exist.
        assist: (msgs) => msgs.isEmpty
            ? const DmAssist(
                mode: 'opener',
                chips: ['Ask about the dog park', 'What trail do you run?'],
              )
            : const DmAssist(mode: 'coach', chips: ['x'], tip: 'keep going'),
      );
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

      // Opener chips show above the composer; no tip for an empty thread.
      expect(find.text('Things to talk about'), findsOneWidget);
      expect(find.text('Ask about the dog park'), findsOneWidget);
      expect(find.byTooltip('Dismiss tip'), findsNothing);
      // Jobs pass cluster 15 (defect 6): the chip's (16, 16) padding lands it
      // at or above the 44pt touch floor.
      final chip = find.ancestor(
        of: find.text('Ask about the dog park'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(44.0));
      // The first fetch was made with an empty tail.
      expect(dm.assistCalls.first, isEmpty);
    },
  );

  testWidgets(
    'coach-mode chips + tip render once messages exist, and the tip is '
    'dismissible',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        assist: (msgs) => msgs.isEmpty
            ? const DmAssist(mode: 'opener', chips: ['opener chip'])
            : const DmAssist(
                mode: 'coach',
                chips: ['Ask what she liked about it'],
                tip: 'She just opened up — match her energy.',
              ),
      );
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
          id: 'm1',
          senderUid: 'a',
          type: 'text',
          body: 'hey!',
          createdAt: DateTime.now(),
        ),
      ]);
      await tester.pump(); // deliver the message
      // The refresh is debounced ~1.5s — advance past it so the coach reply
      // lands, then settle the resulting rebuild.
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pumpAndSettle();

      expect(find.text('Ask what she liked about it'), findsOneWidget);
      expect(
        find.text('She just opened up — match her energy.'),
        findsOneWidget,
      );
      // Jobs pass cluster 15 (defect 9): the coach-tip dismiss renders a full
      // 48 (no compact density).
      final tipDismiss = tester.getSize(find.ancestor(
        of: find.byTooltip('Dismiss tip'),
        matching: find.byType(IconButton),
      ));
      expect(tipDismiss.width, greaterThanOrEqualTo(48.0));
      expect(tipDismiss.height, greaterThanOrEqualTo(48.0));

      // The tip is dismissible and stays gone until a different tip arrives.
      await tester.tap(find.byTooltip('Dismiss tip'));
      await tester.pumpAndSettle();
      expect(
        find.text('She just opened up — match her energy.'),
        findsNothing,
      );
      // Chips are unaffected by dismissing the tip.
      expect(find.text('Ask what she liked about it'), findsOneWidget);
    },
  );

  testWidgets(
    'with the keyboard open the coach tip stays visible directly above the '
    'composer, not clipped behind the keyboard',
    (tester) async {
      // A short window with a tall keyboard, so the coaching region (several
      // chips + a tip) is taller than its cap and must scroll inside it.
      const double screenH = 700, keyboard = 400;
      tester.view.physicalSize = const Size(400, screenH);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(bottom: 0);
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        assist: (_) => const DmAssist(
          mode: 'coach',
          chips: [
            'Ask what she liked most about the trip',
            'Share the playlist you mentioned',
            'Suggest the coffee place downtown',
            'Ask how the half-marathon training is going',
          ],
          tip: "You're sending a lot in a row — give them space to reply first.",
        ),
      );
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

      final tip = find.byTooltip('Dismiss tip');
      expect(tip, findsOneWidget);

      // The keyboard occupies the bottom [keyboard] px; the tip must sit above
      // that line — i.e. it is not hidden behind the keyboard.
      final tipRect = tester.getRect(tip);
      expect(tipRect.bottom, lessThanOrEqualTo(screenH - keyboard),
          reason: 'the tip must render above the keyboard, not behind it');
      expect(tipRect.top, greaterThanOrEqualTo(0.0));

      // …and it is pinned directly above the composer (the chips, not the tip,
      // are what scrolls off when space is tight).
      final composerTop = tester.getTopLeft(_composerPadding()).dy;
      expect(tipRect.bottom, lessThanOrEqualTo(composerTop));

      // Dismiss still works with the keyboard up.
      await tester.tap(tip);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss tip'), findsNothing);
    },
  );

  testWidgets('the tip row is hidden entirely when the tip is null', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(
      ctrl,
      // Coach chips but no tip — the tip row must not appear.
      assist: (msgs) =>
          const DmAssist(mode: 'coach', chips: ['a chip'], tip: null),
    );
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

    expect(find.text('a chip'), findsOneWidget);
    expect(find.byTooltip('Dismiss tip'), findsNothing);
  });

  // --- safety red-flag coach (§6.9.1) ------------------------------------ //

  testWidgets(
    'a safety note renders at warning (distinct from the coach tip) and is '
    'dismissible, without affecting the chips or tip',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        assist: (msgs) => const DmAssist(
          mode: 'coach',
          chips: ['let\'s slow down'],
          tip: 'Trust your gut here.',
          safety: DmSafety(
            level: 'warning',
            reason: 'They keep asking for money — that\'s a common scam '
                'pattern. Be careful.',
            flags: ['money_request'],
          ),
        ),
      );
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

      // The protective heads-up shows, visually distinct from the coach tip:
      // its own shield glyph + label + its own dismiss tooltip.
      expect(find.text('Heads up from Ayma'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      expect(
        find.textContaining('common scam pattern'),
        findsOneWidget,
      );
      expect(find.byTooltip('Dismiss safety note'), findsOneWidget);
      // Jobs pass cluster 15: the shield reads in warningText (defect 11, was
      // 2.01 light), and the dismiss button renders a full 48 (defect 7, no
      // compact density). No explicit theme → context.ac is AymaTokens.dark.
      expect(
        tester.widget<Icon>(find.byIcon(Icons.shield_outlined)).color,
        AymaTokens.dark.warningText,
      );
      final dismiss = tester.getSize(find.ancestor(
        of: find.byTooltip('Dismiss safety note'),
        matching: find.byType(IconButton),
      ));
      expect(dismiss.width, greaterThanOrEqualTo(48.0));
      expect(dismiss.height, greaterThanOrEqualTo(48.0));
      // The normal coach tip + chips coexist (safety is an additional note).
      expect(find.text('Trust your gut here.'), findsOneWidget);
      expect(find.byTooltip('Dismiss tip'), findsOneWidget);
      expect(find.text('let\'s slow down'), findsOneWidget);

      // Dismissing the safety note hides only it — chips + tip remain.
      await tester.tap(find.byTooltip('Dismiss safety note'));
      await tester.pumpAndSettle();
      expect(find.text('Heads up from Ayma'), findsNothing);
      expect(find.textContaining('common scam pattern'), findsNothing);
      expect(find.text('Trust your gut here.'), findsOneWidget);
      expect(find.text('let\'s slow down'), findsOneWidget);
    },
  );

  testWidgets(
    'a safety note renders at caution too',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        assist: (_) => const DmAssist(
          mode: 'coach',
          chips: ['x'],
          safety: DmSafety(
            level: 'caution',
            reason: 'Heads up — they\'re pushing to meet really fast. It\'s '
                'okay to take your time.',
            flags: ['rushing_to_meet'],
          ),
        ),
      );
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

      expect(find.text('Heads up from Ayma'), findsOneWidget);
      expect(find.textContaining('take your time'), findsOneWidget);
    },
  );

  testWidgets(
    'no safety note at level none (the common, false-positive-free case)',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        // Normal flirting: chips + tip, but safety stays silent (none).
        assist: (_) => const DmAssist(
          mode: 'coach',
          chips: ['haha same'],
          tip: 'You\'re vibing — keep it light.',
          safety: DmSafety.none,
        ),
      );
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

      expect(find.text('Heads up from Ayma'), findsNothing);
      expect(find.byIcon(Icons.shield_outlined), findsNothing);
      expect(find.byTooltip('Dismiss safety note'), findsNothing);
      // The normal coaching is unaffected.
      expect(find.text('You\'re vibing — keep it light.'), findsOneWidget);
    },
  );

  testWidgets(
    'a safety note never blocks sending (advisory only)',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        assist: (_) => const DmAssist(
          mode: 'coach',
          chips: ['x'],
          safety: DmSafety(
            level: 'warning',
            reason: 'Be careful here.',
            flags: ['money_request'],
          ),
        ),
      );
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
      expect(find.text('Heads up from Ayma'), findsOneWidget);

      // Typing + sending still works with the note on screen.
      await tester.enterText(find.byType(TextField), 'I am not comfortable');
      // WhatsApp composer model: the send button only exists once text
      // is in the box (the slot shows the mic when empty) - pump the swap.
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();
      expect(dm.sent, contains('I am not comfortable'));
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
    // WhatsApp composer model: the send button only exists once text
    // is in the box (the slot shows the mic when empty) - pump the swap.
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(dm.sent, ['yo']);
    expect(find.text('yo'), findsOneWidget);
  });

  testWidgets('a refused send keeps the composer text and offers Retry',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl)..failNextSends = 1;
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

    await tester.enterText(find.byType(TextField), 'yo');
    // WhatsApp composer model: the send button only exists once text
    // is in the box (the slot shows the mic when empty) - pump the swap.
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(dm.sent, isEmpty);
    expect(find.textContaining('Not sent'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // The original input is still in the composer.
    expect(find.text('yo'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(dm.sent, ['yo']);
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

  testWidgets('renders a GIF attachment inline (animated via Image.network)', (
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
    ctrl.add([
      DmMessage(
        id: 'g1',
        senderUid: 'a',
        type: 'gif',
        body: '',
        createdAt: DateTime.now(),
        attachmentUrl: 'https://example.invalid/party.gif',
        attachmentPath: 'uploads/a/dm/a__me/party.gif',
        mime: 'image/gif',
        fileName: 'party.gif',
        size: 65536,
      ),
    ]);
    await tester.pumpAndSettle();

    // Rendered inline as an image thumbnail (not the '📷 GIF' text fallback)…
    expect(find.byType(Image), findsWidgets);
    expect(find.text('📷 GIF'), findsNothing);
    // …and tappable to the full-screen viewer.
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets(
    'the composer accepts keyboard-inserted media, uploading + sending it as '
    'a gif message',
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
      ctrl.add(const []);
      await tester.pumpAndSettle();

      // The composer declares rich-content support (so Gboard's GIF/image
      // button inserts here instead of the "not supported" toast)…
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.contentInsertionConfiguration, isNotNull);

      // …and inserting a GIF uploads its bytes and sends it as a `gif` message.
      field.contentInsertionConfiguration!.onContentInserted(
        KeyboardInsertedContent(
          mimeType: 'image/gif',
          uri: 'content://gif/1',
          data: Uint8List.fromList(const [1, 2, 3]),
        ),
      );
      await tester.pumpAndSettle();

      expect(dm.insertedUploads.single.mime, 'image/gif');
      expect(dm.attachmentsSent.single.type, 'gif');
    },
  );

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

    // Jobs pass cluster 15 (defects 1–2): the sheet tiles sit at the share
    // sheet's 20-start / 24-end inset, and a 24 bottom space closes the sheet.
    for (final label in ['Photo', 'Camera', 'File']) {
      final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, label));
      expect(tile.contentPadding,
          const EdgeInsetsDirectional.only(start: 20, end: 24));
    }
    expect(
      find.descendant(
        of: find.byType(SafeArea),
        matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.height == 24 && w.width == null),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping a conversation-starter fills the composer and it stays',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        assist: (_) =>
            const DmAssist(mode: 'opener', chips: ['What trail do you run?']),
      );
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

    // Jobs pass cluster 15: the header avatar initial reads in fgDim (defect
    // 3) and the online dot in successText (defect 4). No explicit theme →
    // context.ac is AymaTokens.dark.
    expect(
      tester.widget<Text>(find.text('P')).style?.color,
      AymaTokens.dark.fgDim,
    );
    final onlineDot = tester.widgetList<Container>(find.byType(Container)).where(
      (c) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.shape == BoxShape.circle &&
            d.color == AymaTokens.dark.successText;
      },
    );
    expect(onlineDot, isNotEmpty);
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

  testWidgets(
    'shows FreshnessIndicator when thread messages are from cache (stale)',
    (tester) async {
      final ctrl = StreamController<FreshData<List<DmMessage>>>.broadcast();
      final dm = _FakeDm(
        StreamController<List<DmMessage>>.broadcast(),
        freshCtrl: ctrl,
      );

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
      ctrl.add(const FreshData(
        data: [],
        isFromCache: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(FreshnessIndicator), findsOneWidget);
      expect(find.text('Offline — showing saved data'), findsOneWidget);
    },
  );

  testWidgets(
    'bubbles show WhatsApp-style time labels on both sent + received, with a '
    'date divider chip between different days',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final d1 = DateTime(2026, 10, 30, 9, 41); // received, day 1
      final d2 = DateTime(2026, 10, 31, 14, 15); // sent, day 2

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
          body: 'morning!',
          createdAt: d1,
        ),
        DmMessage(
          id: '2',
          senderUid: 'me',
          type: 'text',
          body: 'hey there',
          createdAt: d2,
        ),
      ]);
      await tester.pumpAndSettle();

      // A time label on each bubble (received + sent).
      expect(find.text(formatMessageTime(d1)), findsOneWidget);
      expect(find.text(formatMessageTime(d2)), findsOneWidget);

      // Jobs pass cluster 15 (defects 12–13): the mine bubble's timestamp is
      // solid onAccent (no 0.72 alpha) and the incoming one is fgDim (not
      // fgMute). No explicit theme → context.ac is AymaTokens.dark.
      expect(
        tester.widget<Text>(find.text(formatMessageTime(d2))).style?.color,
        AymaTokens.dark.onAccent,
      );
      expect(
        tester.widget<Text>(find.text(formatMessageTime(d1))).style?.color,
        AymaTokens.dark.fgDim,
      );

      // A divider chip for each distinct day (the first dated message always
      // gets one; the day change adds the second).
      expect(find.byType(DateDividerChip), findsNWidgets(2));
    },
  );
}
