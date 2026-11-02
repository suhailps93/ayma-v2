import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stub ApiClient whose `/profiles/mini` and `/voice/engines` return empty
/// payloads — the DM screen's best-effort header + preferred-language loads
/// must degrade silently, never block the thread.
ApiClient _api() => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async => http.Response(
            req.url.path == '/profiles/mini' ? jsonEncode({'profiles': {}}) : '{}',
            200,
          )),
    );

/// A DmService whose `translate` is fully controllable, so the widget tests
/// exercise the cross-language UI without a backend.
class _FakeDm extends DmService {
  _FakeDm(this._msgs, {DmTranslation Function(String text)? translate})
      : _translateFn = translate,
        super(
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: 'me'),
          ),
        );

  final StreamController<List<DmMessage>> _msgs;
  final DmTranslation Function(String text)? _translateFn;

  final List<String> sent = [];
  final List<({String text, String target})> translateCalls = [];

  @override
  Stream<List<DmMessage>> watchMessages(String threadId,
      {int limit = 30}) =>
      _msgs.stream;

  @override
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(String threadId,
          {int limit = 30}) =>
      _msgs.stream.map((m) => FreshData(data: m));

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) async =>
      DmAssist.empty;

  @override
  Future<DmTranslation> translate(
    String threadId,
    String text,
    String targetLang, {
    String sourceLang = '',
  }) async {
    translateCalls.add((text: text, target: targetLang));
    return _translateFn?.call(text) ??
        const DmTranslation(translated: '', detectedSourceLang: '');
  }

  @override
  Future<void> sendText(String threadId, String text) async {
    sent.add(text);
    _msgs.add([
      DmMessage(
        id: 'sent-${sent.length}',
        senderUid: 'me',
        type: 'text',
        body: text,
        createdAt: DateTime.now(),
      ),
    ]);
  }
}

DmMessage _incoming(String body, {String id = 'in1'}) => DmMessage(
      id: id,
      senderUid: 'a',
      type: 'text',
      body: body,
      createdAt: DateTime.now(),
    );

void main() {
  testWidgets(
    'an incoming foreign-language bubble shows Translate; tapping renders the '
    'translation with a "translated from" label while keeping the original',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        translate: (_) => const DmTranslation(
          translated: 'How are you?',
          detectedSourceLang: 'es',
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
      ctrl.add([_incoming('¿Cómo estás?')]);
      await tester.pumpAndSettle();

      // The original is shown with a subtle Translate affordance.
      expect(find.text('¿Cómo estás?'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);

      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();

      // The translation renders, the original stays, and the source language
      // is labelled.
      expect(find.text('How are you?'), findsOneWidget);
      expect(find.text('¿Cómo estás?'), findsOneWidget);
      expect(find.textContaining('translated from es'), findsOneWidget);

      // The call targeted a non-empty preferred language (device locale here).
      expect(dm.translateCalls.single.text, '¿Cómo estás?');
      expect(dm.translateCalls.single.target, isNotEmpty);
    },
  );

  testWidgets(
    'an incoming message already in the reader\'s language never shows '
    'Translate: the backend returns the original and no affordance is offered',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      // Same-script (Latin) text the backend resolves to the reader's own
      // language: it hands back the original unchanged (confidence too low / not
      // foreign), so the widget must offer nothing.
      final dm = _FakeDm(
        ctrl,
        translate: (text) => DmTranslation(translated: text),
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
      ctrl.add([_incoming('hey sexy')]);
      await tester.pumpAndSettle();

      // The message shows, but there is NO Translate affordance on English.
      expect(find.text('hey sexy'), findsOneWidget);
      expect(find.text('Translate'), findsNothing);
      expect(find.text('Already in your language'), findsNothing);
    },
  );

  testWidgets(
    'a short different-script (Malayalam) message still offers Translate and '
    'translates on tap — script detection is reliable even when short',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        translate: (_) =>
            const DmTranslation(translated: 'hi', detectedSourceLang: 'ml'),
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
      ctrl.add([_incoming('ഹായ്')]);
      await tester.pumpAndSettle();

      // Offered without any up-front call (reliably foreign by script).
      expect(find.text('ഹായ്'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      expect(dm.translateCalls, isEmpty);

      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();

      expect(find.text('hi'), findsOneWidget);
      expect(find.textContaining('translated from ml'), findsOneWidget);
      expect(dm.translateCalls.single.text, 'ഹായ്');
    },
  );

  testWidgets(
    'outgoing translation is opt-in: off by default the typed text is sent '
    'unchanged; no translate call is made',
    (tester) async {
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
      ctrl.add(const []);
      await tester.pumpAndSettle();

      // Outgoing translation is off by default: no "will translate" banner
      // shows (the control itself is the menu toggle exercised in the next
      // test).
      expect(find.textContaining('Ayma will translate your message'),
          findsNothing);

      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      // Default (off): sent verbatim, and translation was never invoked.
      expect(dm.sent, ['hello there']);
      expect(dm.translateCalls, isEmpty);
    },
  );

  testWidgets(
    'with outgoing translation enabled and the match language known, the send '
    'flow previews the translation and only sends it once confirmed',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = _FakeDm(
        ctrl,
        // Incoming detects 'es'; the outgoing draft translates to a preview.
        translate: (text) => text == 'see you tomorrow'
            ? const DmTranslation(
                translated: 'hasta mañana', detectedSourceLang: 'en')
            : const DmTranslation(
                translated: 'Hello', detectedSourceLang: 'es'),
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
      ctrl.add([_incoming('Hola')]);
      await tester.pumpAndSettle();

      // Translate an incoming message so the match's language ('es') is known.
      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();

      // Turn on "translate what I send" from the thread menu, type a draft,
      // and send.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Translate what I send'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ayma will translate your message'),
          findsOneWidget);
      await tester.enterText(find.byType(TextField), 'see you tomorrow');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      // A preview shows exactly what will be sent, with the original kept.
      expect(find.text('Send in their language?'), findsOneWidget);
      expect(find.text('hasta mañana'), findsOneWidget);
      // The original is kept visible in the preview (and still in the composer).
      expect(find.text('see you tomorrow'), findsWidgets);
      // Nothing sent until the user confirms.
      expect(dm.sent, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      // The translated text is what actually gets sent.
      expect(dm.sent, ['hasta mañana']);
    },
  );
}
