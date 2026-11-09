import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_chat_modal.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
const _sseUtf8 = {'content-type': 'text/event-stream; charset=utf-8'};

class _CaptureClient {
  final requests = <Map<String, dynamic>>[];

  ApiClient api() {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      if (request.url.path == '/chat/stream') {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        final body = [
          'data: ${jsonEncode({
                'type': 'reply',
                'text': 'Reply from Ayma.',
                'tools_used': <String>[],
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200, headers: _sseUtf8);
      }
      if (request.url.path == '/chat') {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'reply': 'Reply from Ayma.',
            'tools_used': <String>[],
            'capped': false,
            'fallback_form': false,
            'usage_capped': false,
          }),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    return ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );
  }
}

class _TestVoice extends VoiceSessionController {
  _TestVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _fakePhase = VoiceSessionPhase.idle;

  @override
  VoiceSessionPhase get phase => _fakePhase;

  @override
  bool get isActive =>
      _fakePhase == VoiceSessionPhase.connecting ||
      _fakePhase == VoiceSessionPhase.waking ||
      _fakePhase == VoiceSessionPhase.live;

  @override
  bool get isListening => _fakePhase == VoiceSessionPhase.live;

  void setPhase(VoiceSessionPhase p) {
    _fakePhase = p;
    notifyListeners();
  }
}

void main() {
  setUp(() {
    AppContext.instance.set(screen: '');
  });

  testWidgets(
    'chip pinned plus a text send carries the screen context on the wire',
    (tester) async {
      final capture = _CaptureClient();
      final voice = _TestVoice();
      const ctx = ScreenContext(
        screen: 'explore',
        note: 'hiking in boulder',
        route: '/explore',
        detail: '3 people nearby',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
              pageContext: ctx,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The pinned chip is visible with its label
      expect(find.text('Explore — "hiking in boulder"'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

      // Enter text and send
      await tester.enterText(find.byType(TextField), 'what can I do here?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(1));
      final sent = capture.requests.first;
      expect(sent['message'], 'what can I do here?');
      // The page REFERENCE rides inline — slug, route and the small note.
      expect(sent['screen'], 'explore');
      expect(sent['screen_note'], 'hiking in boulder');
      expect(sent['screen_route'], '/explore');
      // …but the whole-page snapshot (`detail`/`visible`) does NOT: Ayma
      // describes the page server-side from the reference (founder
      // 2026-11-09: reference, not content).
      expect(sent.containsKey('screen_detail'), isFalse);
      expect(sent.containsKey('screen_visible'), isFalse);
    },
  );

  testWidgets(
    'the pinned chip is hidden while a voice call is active so it never claims '
    'context the voice session does not receive',
    (tester) async {
      final capture = _CaptureClient();
      final voice = _TestVoice();
      const ctx = ScreenContext(screen: 'explore', note: 'hiking');

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
              pageContext: ctx,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Chip visible when idle
      expect(find.text('Explore — "hiking"'), findsOneWidget);

      // Voice goes connecting -> waking -> live
      voice.setPhase(VoiceSessionPhase.connecting);
      await tester.pump();
      expect(find.text('Explore — "hiking"'), findsNothing);

      voice.setPhase(VoiceSessionPhase.live);
      await tester.pump();
      expect(find.text('Explore — "hiking"'), findsNothing);

      // Voice ends -> chip returns for text composer
      voice.setPhase(VoiceSessionPhase.idle);
      await tester.pump();
      expect(find.text('Explore — "hiking"'), findsOneWidget);
    },
  );

  testWidgets(
    'the full-screen state does not silently claim the dropped context: chip is '
    'dropped while expanded and send carries empty screen context; collapsed state '
    'restores the chip and sends context',
    (tester) async {
      final capture = _CaptureClient();
      final voice = _TestVoice();
      final sheet = AymaChatSheetController();
      addTearDown(sheet.dispose);

      const ctx = ScreenContext(
        screen: 'explore',
        note: 'rock climbing',
        route: '/explore',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAymaChatModal(
                  context,
                  controller: sheet,
                  builder: (_) => ChatScreen(
                    apiClient: capture.api(),
                    voiceController: voice,
                    pageContext: ctx,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // In docked state: chip is visible
      expect(find.text('Explore — "rock climbing"'), findsOneWidget);

      // Expand to full-screen
      await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
      await tester.pumpAndSettle();
      expect(sheet.isExpanded, isTrue);

      // Full-screen state: chip is dropped
      expect(find.text('Explore — "rock climbing"'), findsNothing);

      // Send text while expanded
      await tester.enterText(find.byType(TextField), 'msg in full screen');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(1));
      final fullSend = capture.requests.first;
      expect(fullSend['message'], 'msg in full screen');
      // Full screen state does NOT silently claim dropped context
      expect(fullSend['screen'], '');
      expect(fullSend['screen_note'], '');
      expect(fullSend['screen_route'], '');
      expect(fullSend['screen_previous_route'], '');
      expect(fullSend['screen_previous_label'], '');

      // Collapse back to docked
      await tester.tap(find.byKey(const Key('chatCollapseFullscreenButton')));
      await tester.pumpAndSettle();
      expect(sheet.isExpanded, isFalse);

      // Collapsed: chip reappears
      expect(find.text('Explore — "rock climbing"'), findsOneWidget);

      // Send text in docked state
      await tester.enterText(find.byType(TextField), 'msg in docked');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(2));
      final dockedSend = capture.requests[1];
      expect(dockedSend['message'], 'msg in docked');
      // Docked send carries the screen context
      expect(dockedSend['screen'], 'explore');
      expect(dockedSend['screen_note'], 'rock climbing');
      expect(dockedSend['screen_route'], '/explore');
    },
  );

  testWidgets(
    'clearing the pinned chip removes it and sends empty screen context',
    (tester) async {
      final capture = _CaptureClient();
      final voice = _TestVoice();
      const ctx = ScreenContext(screen: 'explore', note: 'hiking');

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
              pageContext: ctx,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Explore — "hiking"'), findsOneWidget);

      // Tap remove page context
      await tester.tap(find.byTooltip('Remove page context'));
      await tester.pumpAndSettle();

      expect(find.text('Explore — "hiking"'), findsNothing);

      // Send message
      await tester.enterText(find.byType(TextField), 'plain message');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(1));
      final sent = capture.requests.first;
      expect(sent['message'], 'plain message');
      expect(sent['screen'], '');
      expect(sent['screen_note'], '');
      expect(sent['screen_previous_route'], '');
    },
  );
}
