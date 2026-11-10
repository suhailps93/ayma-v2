import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:ayma_flutter/theme.dart';
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

Future<_FakeDm> _pumpThread(
  WidgetTester tester,
  StreamController<List<DmMessage>> ctrl, {
  DmTranslation Function(String text)? translate,
}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final dm = _FakeDm(ctrl, translate: translate);
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
  return dm;
}

void main() {
  testWidgets(
    'a foreign-language bubble gets a Translate button under it; tapping '
    'swaps the bubble text to the translation in place, and the button '
    'toggles back to the original',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = await _pumpThread(
        tester,
        ctrl,
        translate: (_) => const DmTranslation(
          translated: 'How are you?',
          detectedSourceLang: 'es',
        ),
      );
      ctrl.add([_incoming('¿Cómo estás?')]);
      await tester.pumpAndSettle();

      // The original is shown, with a Translate button under the bubble.
      expect(find.text('¿Cómo estás?'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      // Jobs pass cluster 15 (defect 19): the Translate label reads in
      // accentText (was raw accent, 3.83 light). No explicit theme →
      // context.ac is AymaTokens.dark.
      expect(
        tester.widget<Text>(find.text('Translate')).style?.color,
        AymaTokens.dark.accentText,
      );
      // Same-script detection ran exactly once, quietly, in the background.
      expect(dm.translateCalls, hasLength(1));
      expect(dm.translateCalls.single.text, '¿Cómo estás?');
      expect(dm.translateCalls.single.target, isNotEmpty);

      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();

      // The bubble now shows the translation INSTEAD of the original, with
      // the source language labelled and a way back on the same button.
      expect(find.text('How are you?'), findsOneWidget);
      expect(find.text('¿Cómo estás?'), findsNothing);
      expect(find.textContaining('translated from es'), findsOneWidget);
      expect(find.text('Show original'), findsOneWidget);
      // Revealing did not re-translate.
      expect(dm.translateCalls, hasLength(1));

      await tester.tap(find.text('Show original'));
      await tester.pumpAndSettle();
      expect(find.text('¿Cómo estás?'), findsOneWidget);
      expect(find.text('How are you?'), findsNothing);
      expect(find.text('Show translation'), findsOneWidget);

      await tester.tap(find.text('Show translation'));
      await tester.pumpAndSettle();
      expect(find.text('How are you?'), findsOneWidget);
      expect(dm.translateCalls, hasLength(1));
    },
  );

  testWidgets(
    'an incoming message already in the reader\'s language never shows a '
    'Translate button: the backend returns the original and nothing is '
    'offered',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      // Same-script (Latin) text the backend resolves to the reader's own
      // language: it hands back the original unchanged (confidence too low /
      // not foreign), so the widget must offer nothing.
      await _pumpThread(
        tester,
        ctrl,
        translate: (text) => DmTranslation(translated: text),
      );
      ctrl.add([_incoming('hey sexy')]);
      await tester.pumpAndSettle();

      expect(find.text('hey sexy'), findsOneWidget);
      expect(find.text('Translate'), findsNothing);
      expect(find.text('Show original'), findsNothing);
      expect(find.text('Show translation'), findsNothing);
    },
  );

  testWidgets(
    'a short different-script (Malayalam) message still gets a Translate '
    'button with no up-front call — script detection is reliable even when '
    'short — and the button hit area is a full 48pt tall, below the bubble',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = await _pumpThread(
        tester,
        ctrl,
        translate: (_) =>
            const DmTranslation(translated: 'hi', detectedSourceLang: 'ml'),
      );
      ctrl.add([_incoming('ഹായ്')]);
      await tester.pumpAndSettle();

      // Offered without any up-front call (reliably foreign by script).
      expect(find.text('ഹായ്'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      expect(dm.translateCalls, isEmpty);

      // The button sits below the bubble and its hit area is 48pt tall.
      final btn = find.byKey(const ValueKey('translate-btn-in1'));
      expect(btn, findsOneWidget);
      expect(tester.getSize(btn).height, 48);
      expect(
        tester.getTopLeft(btn).dy,
        greaterThan(tester.getBottomLeft(find.text('ഹായ്')).dy),
      );

      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();

      expect(find.text('hi'), findsOneWidget);
      expect(find.text('ഹായ്'), findsNothing);
      expect(find.textContaining('translated from ml'), findsOneWidget);
      expect(find.text('Show original'), findsOneWidget);
      expect(dm.translateCalls.single.text, 'ഹായ്');
    },
  );

  testWidgets(
    'my own message never gets a Translate button, even in a foreign '
    'language',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = await _pumpThread(
        tester,
        ctrl,
        translate: (_) =>
            const DmTranslation(translated: 'hi', detectedSourceLang: 'ml'),
      );
      ctrl.add([
        DmMessage(
          id: 'mine1',
          senderUid: 'me',
          type: 'text',
          body: 'ഹായ്',
          createdAt: DateTime.now(),
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('ഹായ്'), findsOneWidget);
      expect(find.text('Translate'), findsNothing);
      expect(dm.translateCalls, isEmpty);
    },
  );

  testWidgets(
    'a resolved translation is cached: a list rebuild does not re-detect or '
    're-translate the same message',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = await _pumpThread(
        tester,
        ctrl,
        translate: (text) => text == '¿Cómo estás?'
            ? const DmTranslation(
                translated: 'How are you?', detectedSourceLang: 'es')
            : DmTranslation(translated: text),
      );
      final first = _incoming('¿Cómo estás?');
      ctrl.add([first]);
      await tester.pumpAndSettle();
      expect(dm.translateCalls, hasLength(1));

      // A rebuild with the same message plus a new one: the resolved message
      // is not detected again.
      ctrl.add([first, _incoming('good morning', id: 'in2')]);
      await tester.pumpAndSettle();
      final callsForFirst =
          dm.translateCalls.where((c) => c.text == '¿Cómo estás?').length;
      expect(callsForFirst, 1);
      expect(find.text('Translate'), findsOneWidget);
    },
  );

  testWidgets(
    'the thread menu holds only Share this chat with Ayma and Block & '
    'report — both translate options are gone',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      await _pumpThread(tester, ctrl);
      ctrl.add(const []);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Share this chat with Ayma'), findsOneWidget);
      expect(find.text('Block & report'), findsOneWidget);
      expect(find.text('Auto-translate their messages'), findsNothing);
      expect(find.text('Translate what I send'), findsNothing);
    },
  );

  testWidgets(
    'sending is never translated: typed text is sent exactly as typed, with '
    'no preview sheet and no translate call for the draft',
    (tester) async {
      final ctrl = StreamController<List<DmMessage>>.broadcast();
      final dm = await _pumpThread(
        tester,
        ctrl,
        translate: (_) => const DmTranslation(
          translated: 'Hello',
          detectedSourceLang: 'es',
        ),
      );
      ctrl.add([_incoming('Hola')]);
      await tester.pumpAndSettle();

      // Even after reading a foreign message, there is no "will translate"
      // banner and no menu option to turn outgoing translation on.
      expect(find.textContaining('Ayma will translate your message'),
          findsNothing);

      await tester.enterText(find.byType(TextField), 'see you tomorrow');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Send in their language?'), findsNothing);
      expect(dm.sent, ['see you tomorrow']);
      // Only the incoming detection call happened; the draft never went
      // through translation.
      expect(
        dm.translateCalls.where((c) => c.text == 'see you tomorrow'),
        isEmpty,
      );
    },
  );
}
