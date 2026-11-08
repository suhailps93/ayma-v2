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
  _CaptureClient({this.historyMessages = const []});

  final List<Map<String, dynamic>> historyMessages;
  final requests = <Map<String, dynamic>>[];

  ApiClient api() {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({'messages': historyMessages, 'next_before': null}),
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
    'reply-card UI: opening chat from explore shows quoted reply card naming the real subject in the thread and sends whole page context',
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

      // Pinned chip is in the composer naming the real subject
      expect(find.text('Explore — "hiking in boulder"'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

      // Send first message
      await tester.enterText(find.byType(TextField), 'what can I do here?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      // Check request carries whole page context
      expect(capture.requests, hasLength(1));
      final sent1 = capture.requests.first;
      expect(sent1['message'], 'what can I do here?');
      expect(sent1['screen'], 'explore');
      expect(sent1['screen_note'], 'hiking in boulder');
      expect(sent1['screen_route'], '/explore');
      expect(sent1['screen_detail'], '3 people nearby');

      // In the thread: quoted reply card appears above the user message naming real subject
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
      expect(find.text('Explore — "hiking in boulder"'), findsOneWidget);
      expect(find.text('what can I do here?'), findsOneWidget);

      // Next message is normal: stays plain and carries nothing
      await tester.enterText(find.byType(TextField), 'second plain message');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(2));
      final sent2 = capture.requests[1];
      expect(sent2['message'], 'second plain message');
      expect(sent2['screen'], '');
      expect(sent2['screen_note'], '');
      expect(sent2['screen_route'], '');

      // Only the first message has the quotedReplyCard
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
    },
  );

  testWidgets(
    'reply-card UI: opening chat from a profile pins the profile, never parent section name',
    (tester) async {
      final capture = _CaptureClient();
      final voice = _TestVoice();
      const ctx = ScreenContext(
        screen: 'profile',
        subjectName: 'Sarah',
        subjectUid: 'sarah-uid-456',
        route: '/profile/user/sarah-uid-456',
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

      // Names the profile, never "Explore" or "Matches"
      expect(find.text("Sarah's profile"), findsOneWidget);
      expect(find.text('Explore'), findsNothing);
      expect(find.text('Matches'), findsNothing);

      // Send message
      await tester.enterText(find.byType(TextField), 'tell me about her');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(1));
      final sent = capture.requests.first;
      expect(sent['message'], 'tell me about her');
      expect(sent['screen'], 'profile');
      expect(sent['screen_subject_name'], 'Sarah');
      expect(sent['screen_subject_uid'], 'sarah-uid-456');

      // Thread bubble has quoted reply card naming Sarah's profile
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
      expect(find.text("Sarah's profile"), findsOneWidget);
    },
  );

  testWidgets(
    'founder rules: half-screen keeps pin and reply card, full-screen drops pin and context, voice drops pin and context',
    (tester) async {
      final capture = _CaptureClient();
      final voice = _TestVoice();
      final sheet = AymaChatSheetController();
      final store = TranscriptStore();
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
                    transcriptStore: store,
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

      // Half-screen docked state: pin is visible
      expect(find.text('Explore — "rock climbing"'), findsOneWidget);

      // Expand to full-screen
      await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
      await tester.pumpAndSettle();
      expect(sheet.isExpanded, isTrue);

      // Full-screen: pin is dropped
      expect(find.text('Explore — "rock climbing"'), findsNothing);

      // Send text in full-screen: stays plain, carries nothing
      await tester.enterText(find.byType(TextField), 'full screen message');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(1));
      final fullSend = capture.requests.first;
      expect(fullSend['screen'], '');
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsNothing);

      // Collapse back to docked
      await tester.tap(find.byKey(const Key('chatCollapseFullscreenButton')));
      await tester.pumpAndSettle();
      expect(sheet.isExpanded, isFalse);

      // Collapsed: pin returns
      expect(find.text('Explore — "rock climbing"'), findsOneWidget);

      // Send in docked: carries context and lands in store with replySubject
      await tester.enterText(find.byType(TextField), 'docked message');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(2));
      final dockedSend = capture.requests[1];
      expect(dockedSend['screen'], 'explore');
      expect(store.turns.any((t) => t.replySubject == 'Explore — "rock climbing"'), isTrue);

      // Expand sheet to view conversation: quotedReplyCard is rendered
      await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);

      // Voice mode: NO pinned context
      voice.setPhase(VoiceSessionPhase.connecting);
      await tester.pump();
      expect(find.byTooltip('Remove page context'), findsNothing);
    },
  );

  testWidgets(
    'swipe to reply: swiping Ayma message shows preview in composer, cancel dismisses preview',
    (tester) async {
      final capture = _CaptureClient(
        historyMessages: [
          {
            'role': 'ayma',
            'text': 'I found three trails near Boulder: Chautauqua, Mount Sanitas, and Flatirons.',
          },
        ],
      );
      final voice = _TestVoice();

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('composerReplyPreview')), findsNothing);

      // Swipe the Ayma message to reply
      await tester.fling(
        find.textContaining('I found three trails'),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();

      // Reply preview is now visible in the composer
      expect(find.byKey(const ValueKey('composerReplyPreview')), findsOneWidget);
      expect(find.text('Replying to Ayma'), findsOneWidget);
      expect(find.textContaining('I found three trails'), findsNWidgets(2)); // in message and in preview

      // Tap Cancel reply
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();

      // Preview is gone
      expect(find.byKey(const ValueKey('composerReplyPreview')), findsNothing);
    },
  );

  testWidgets(
    'swipe to reply: sending sends the message with quoted context on wire and renders quoted reply card in thread',
    (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();
      final capture = _CaptureClient(
        historyMessages: [
          {
            'role': 'ayma',
            'text': 'Would you prefer hiking or coffee for the first date?',
            'created_at': yesterday,
          },
        ],
      );
      final voice = _TestVoice();

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Swipe the day-old message to reply
      await tester.fling(
        find.textContaining('Would you prefer hiking'),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('composerReplyPreview')), findsOneWidget);

      // Enter response and send
      await tester.enterText(find.byType(TextField), 'Hiking definitely!');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      // Wire message carries the quoted text and context so Ayma remembers
      expect(capture.requests, hasLength(1));
      final sent1 = capture.requests.first;
      expect(
        sent1['message'],
        '[Replying to Ayma: "Would you prefer hiking or coffee for the first date?"]\nHiking definitely!',
      );

      // In the thread: quoted reply card appears inside the user message bubble
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.text('Ayma'),
        ),
        findsOneWidget,
      );
      expect(find.text('Would you prefer hiking or coffee for the first date?'), findsNWidgets(2)); // in Ayma turn and in quoted reply card
      expect(find.text('Hiking definitely!'), findsOneWidget);

      // Next message is normal: stays plain and carries nothing
      await tester.enterText(find.byType(TextField), 'What time should we meet?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      expect(capture.requests, hasLength(2));
      final sent2 = capture.requests[1];
      expect(sent2['message'], 'What time should we meet?');

      // Only the first message has the quotedReplyCard
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
    },
  );

  testWidgets(
    'swipe to reply on user own message: swiping own message shows Replying to You preview in composer, cancel dismisses preview',
    (tester) async {
      final capture = _CaptureClient(
        historyMessages: [
          {
            'role': 'user',
            'text': 'I prefer Italian food for our dinner date.',
          },
        ],
      );
      final voice = _TestVoice();

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('composerReplyPreview')), findsNothing);

      // Swipe user's own sent message to reply
      await tester.fling(
        find.textContaining('I prefer Italian food'),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();

      // Reply preview is now visible in the composer naming "You" honestly
      expect(find.byKey(const ValueKey('composerReplyPreview')), findsOneWidget);
      expect(find.text('Replying to You'), findsOneWidget);
      expect(find.textContaining('I prefer Italian food'), findsNWidgets(2)); // in user bubble and in preview

      // Tap Cancel reply
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();

      // Preview is gone
      expect(find.byKey(const ValueKey('composerReplyPreview')), findsNothing);
    },
  );

  testWidgets(
    'swipe to reply on user own message: sending sends message with quoted context on wire naming You and renders quoted reply card naming You as message quote, not page card',
    (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();
      final capture = _CaptureClient(
        historyMessages: [
          {
            'role': 'user',
            'text': 'I am looking for someone who loves rock climbing.',
            'created_at': yesterday,
          },
        ],
      );
      final voice = _TestVoice();

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Swipe own message to reply
      await tester.fling(
        find.textContaining('loves rock climbing'),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('composerReplyPreview')), findsOneWidget);
      expect(find.text('Replying to You'), findsOneWidget);

      // Enter follow-up and send
      await tester.enterText(find.byType(TextField), 'Especially bouldering at the gym!');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composerSendButton')));
      await tester.pumpAndSettle();

      // Wire message carries the quoted text naming You honestly
      expect(capture.requests, hasLength(1));
      final sent1 = capture.requests.first;
      expect(
        sent1['message'],
        '[Replying to You: "I am looking for someone who loves rock climbing."]\nEspecially bouldering at the gym!',
      );

      // In the thread: quoted reply card appears inside the new user message bubble naming "You"
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.text('You'),
        ),
        findsOneWidget,
      );
      // Quoted reply card renders with reply icon, NEVER with page pin icon
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.byIcon(Icons.reply_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.byIcon(Icons.push_pin_outlined),
        ),
        findsNothing,
      );
      expect(find.text('I am looking for someone who loves rock climbing.'), findsNWidgets(2));
      expect(find.text('Especially bouldering at the gym!'), findsOneWidget);
    },
  );

  testWidgets(
    'history restore: restored self-quote restores and renders as a message quote, never as a page card',
    (tester) async {
      final capture = _CaptureClient(
        historyMessages: [
          {
            'role': 'user',
            'text': 'I love bouldering in the gym.',
            'created_at': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
          },
          {
            'role': 'user',
            'text': '[Replying to You: "I love bouldering in the gym."]\nAnd outdoor sport climbing too!',
            'created_at': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
          },
        ],
      );
      final voice = _TestVoice();

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: ChatScreen(
              apiClient: capture.api(),
              voiceController: voice,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Quoted reply card is restored from history
      expect(find.byKey(const ValueKey('quotedReplyCard')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.text('You'),
        ),
        findsOneWidget,
      );
      // Must be a message quote with reply icon, NEVER a page card with pin icon
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.byIcon(Icons.reply_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('quotedReplyCard')),
          matching: find.byIcon(Icons.push_pin_outlined),
        ),
        findsNothing,
      );
      expect(find.text('I love bouldering in the gym.'), findsNWidgets(2));
      expect(find.text('And outdoor sport climbing too!'), findsOneWidget);
    },
  );
}
