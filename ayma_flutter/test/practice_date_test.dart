import 'dart:convert';

import 'package:ayma_flutter/features/practice_date/practice_debrief_screen.dart';
import 'package:ayma_flutter/features/practice_date/practice_models.dart';
import 'package:ayma_flutter/features/practice_date/practice_screen.dart';
import 'package:ayma_flutter/features/practice_date/practice_voice_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A network-free [VoiceSessionController] for the voice-simulator screen
/// tests — overrides the lifecycle so nothing touches LiveKit, wakelock or
/// permissions (which otherwise leave the widget test hanging).
class _FakePracticeVoice extends VoiceSessionController {
  _FakePracticeVoice()
      : super(transcriptStore: TranscriptStore(), practiceOtherUid: 'her');

  VoiceSessionPhase _p = VoiceSessionPhase.idle;
  String _coach = '';

  @override
  VoiceSessionPhase get phase => _p;

  @override
  bool get isActive =>
      _p == VoiceSessionPhase.connecting ||
      _p == VoiceSessionPhase.waking ||
      _p == VoiceSessionPhase.live;

  @override
  bool get isListening => _p == VoiceSessionPhase.live;

  @override
  bool get agentSpeaking => false;

  @override
  bool get muted => false;

  @override
  String get coachHint => _coach;

  @override
  String get practiceSessionId => 'practice_v1';

  @override
  PracticePersona? get practicePersona => const PracticePersona(
        name: 'Dana',
        age: 30,
        location: 'Berlin',
        photoCount: 2,
      );

  @override
  Future<void> start() async {
    _p = VoiceSessionPhase.connecting;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _p = VoiceSessionPhase.live;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _p = VoiceSessionPhase.idle;
    notifyListeners();
  }

  @override
  Future<void> toggleMute() async {}

  void setCoach(String hint) {
    _coach = hint;
    notifyListeners();
  }
}

// --- Practice simulator screen -------------------------------------------- //

/// JSON response with an explicit UTF-8 charset, matching what the FastAPI
/// backend sends. Without it `http.Response` defaults to latin1 and mangles
/// non-ASCII (e.g. the em-dash in the banner), which production never does.
http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

ApiClient _practiceApi({
  Map<String, dynamic>? start,
  Map<String, dynamic>? chat,
  int startStatus = 200,
}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/practice/start') {
        if (startStatus != 200) return http.Response('no', startStatus);
        return _json(start ??
            {
              'session_id': 'practice_1',
              'simulation': true,
              'persona': {
                'name': 'Dana',
                'age': 30,
                'location': 'Berlin',
                'photo_count': 2,
              },
              'banner':
                  "Practice mode — you're talking to a simulated version of Dana, not the real person.",
            });
      }
      if (req.url.path == '/practice/chat') {
        return _json(chat ??
            {
              'reply': 'haha thanks! what got you into climbing?',
              'coach_hint': 'Great opener — now ask an open question back.',
              'simulation': true,
            });
      }
      return http.Response('no', 404);
    }),
  );
}

Widget _wrap(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? AymaTheme.dark, home: child);

/// Settle an async-loading screen without hanging on its loading spinner
/// (an infinite `CircularProgressIndicator` never lets `pumpAndSettle` finish).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('simulator shows a persistent simulation banner', (tester) async {
    await tester.pumpWidget(_wrap(PracticeScreen(uid: 'her', api: _practiceApi())));
    await _settle(tester);

    expect(find.byKey(const Key('practiceBanner')), findsOneWidget);
    expect(find.textContaining('simulated version of Dana'), findsOneWidget);
    expect(find.textContaining('Practice with Dana'), findsOneWidget);
  });

  testWidgets('sending a message shows the reply and a coach hint',
      (tester) async {
    await tester.pumpWidget(_wrap(PracticeScreen(uid: 'her', api: _practiceApi())));
    await _settle(tester);

    await tester.enterText(find.byKey(const Key('practiceInput')), 'hey!');
    await tester.tap(find.byKey(const Key('practiceSendButton')));
    await _settle(tester);

    expect(find.text('hey!'), findsOneWidget); // user bubble
    expect(find.textContaining('what got you into climbing'), findsOneWidget);
    expect(find.byKey(const Key('practiceCoachHint')), findsOneWidget);
    expect(find.textContaining('open question'), findsOneWidget);
    // End appears once a conversation has started.
    expect(find.byKey(const Key('practiceEndButton')), findsOneWidget);
  });

  testWidgets('both themes render the banner', (tester) async {
    for (final theme in [AymaTheme.light, AymaTheme.dark]) {
      await tester.pumpWidget(
          _wrap(PracticeScreen(uid: 'her', api: _practiceApi()), theme: theme));
      await _settle(tester);
      expect(find.byKey(const Key('practiceBanner')), findsOneWidget);
    }
  });

  testWidgets('a profile with no simulatable person shows an error',
      (tester) async {
    await tester.pumpWidget(
        _wrap(PracticeScreen(uid: 'her', api: _practiceApi(startStatus: 404))));
    await _settle(tester);
    expect(find.byKey(const Key('practiceError')), findsOneWidget);
  });

  // --- Debrief screen ------------------------------------------------------ //

  testWidgets('debrief renders the three coaching sections', (tester) async {
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/practice/debrief') {
          return _json({
            'simulation': true,
            'what_worked': ['You kept it light and curious.'],
            'suggested_next_lines': ['Ask what she is throwing on the wheel.'],
            'avoid': ['Do not push for her address.'],
          });
        }
        return http.Response('no', 404);
      }),
    );
    await tester.pumpWidget(_wrap(
        PracticeDebriefScreen(sessionId: 'practice_1', name: 'Dana', api: api)));
    await _settle(tester);

    expect(find.byKey(const Key('practiceDebrief')), findsOneWidget);
    expect(find.byKey(const Key('debriefWhatWorked')), findsOneWidget);
    expect(find.byKey(const Key('debriefNextLines')), findsOneWidget);
    expect(find.byKey(const Key('debriefAvoid')), findsOneWidget);
    expect(find.textContaining('light and curious'), findsOneWidget);
    expect(find.textContaining('throwing on the wheel'), findsOneWidget);
    expect(find.textContaining('push for her address'), findsOneWidget);
  });

  // --- Voice practice (hackathon B) ---------------------------------------- //

  testWidgets('voice simulator shows the persona header and a live coach hint',
      (tester) async {
    final voice = _FakePracticeVoice();
    await tester.pumpWidget(
        _wrap(PracticeVoiceScreen(uid: 'her', name: 'Dana', voice: voice)));
    await tester.pump(); // runs the post-frame start()
    await tester.pump(const Duration(milliseconds: 10)); // -> live

    expect(find.byKey(const Key('practiceVoiceBanner')), findsOneWidget);
    expect(find.textContaining('simulated version of Dana'), findsOneWidget);
    expect(voice.phase, VoiceSessionPhase.live);

    // A live coach nudge — shown as a side hint, never spoken by the persona.
    voice.setCoach('Ask an open question back.');
    await tester.pump();
    expect(find.byKey(const Key('practiceVoiceCoachHint')), findsOneWidget);
    expect(find.textContaining('open question'), findsOneWidget);
  });

  testWidgets('ending a voice practice returns the session id so the caller '
      'can open the debrief', (tester) async {
    final voice = _FakePracticeVoice();
    String? popped;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => PracticeVoiceScreen(
                      uid: 'her', name: 'Dana', voice: voice),
                ),
              );
              done = true;
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10)); // -> live

    await tester.tap(find.byKey(const Key('practiceVoiceEndButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(done, isTrue);
    expect(popped, 'practice_v1');
  });

  testWidgets('the text simulator shows a voice-practice button', (tester) async {
    await tester.pumpWidget(_wrap(PracticeScreen(uid: 'her', api: _practiceApi())));
    await _settle(tester);
    expect(find.byKey(const Key('practiceVoiceButton')), findsOneWidget);
  });

  // --- Practice button on the profile rail --------------------------------- //

  testWidgets('profile shows a Practice button that opens the simulator',
      (tester) async {
    final pushed = <String>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore/profile/her') {
          return http.Response(
            jsonEncode({
              'uid': 'her',
              'self': false,
              'blocked': false,
              'name': 'Dana',
              'age': 30,
              'location': 'Berlin',
              'photos': <String>[],
              'pages': const [
                {'page_type': 'identity', 'title': '', 'body': 'Lives in Berlin.'},
              ],
              'liked': false,
              'score': null,
              'thread_id': 'her__me',
              'has_chatted': false,
              'deep_dive_id': '',
            }),
            200,
          );
        }
        if (req.url.path == '/report/public_profile/her' ||
            req.url.path == '/report/story_public/her') {
          return http.Response(
            jsonEncode({
              'title': 'Dana',
              'sections': const [
                {
                  'heading': 'Identity',
                  'blocks': [
                    {
                      'block_id': 'sec:0:sent:0',
                      'type': 'text',
                      'editable': false,
                      'text': 'Lives in Berlin.'
                    }
                  ]
                }
              ],
              'meta': {
                'owner_uid': 'her',
                'viewer_can_edit': false,
                'created_at': null,
                'updated_at': null,
              },
            }),
            200,
          );
        }
        return http.Response('no', 404);
      }),
    );
    final router = GoRouter(
      initialLocation: '/profile/user/her',
      routes: [
        GoRoute(
          path: '/profile/user/:uid',
          builder: (_, s) =>
              PublicProfileScreen(uid: s.pathParameters['uid']!, api: api),
        ),
        GoRoute(
          path: '/practice/:uid',
          builder: (_, s) {
            pushed.add('/practice/${s.pathParameters['uid']}');
            return const Scaffold(body: Text('PRACTICE SIM'));
          },
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await _settle(tester);

    final btn = find.byKey(const Key('profilePracticeButton'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await _settle(tester);
    expect(pushed, contains('/practice/her'));
    expect(find.text('PRACTICE SIM'), findsOneWidget);
  });
}
