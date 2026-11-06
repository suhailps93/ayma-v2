import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/async_voice_controller.dart';
import 'package:ayma_flutter/services/async_voice_player.dart';
import 'package:ayma_flutter/services/async_voice_queue.dart';
import 'package:ayma_flutter/services/async_voice_recorder.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  String? _errorMessage;
  bool failNextStart = false;

  @override
  VoiceSessionPhase get phase => _phase;

  @override
  String? get errorMessage => _errorMessage;

  @override
  bool get isActive => _phase == VoiceSessionPhase.live;

  @override
  bool get isListening => _phase == VoiceSessionPhase.live;

  @override
  Future<void> start() async {
    if (!failNextStart) return; // idle tap: stay idle (tap path untouched)
    _phase = VoiceSessionPhase.connecting;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _errorMessage = 'Could not reach Ayma. Check your connection.';
    _phase = VoiceSessionPhase.error;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _phase = VoiceSessionPhase.idle;
    notifyListeners();
  }
}

class _FakeRecorder implements AsyncVoiceRecorder {
  bool allowed = true;
  String? lastPath;

  @override
  Future<bool> ensurePermission() async => allowed;

  @override
  Future<void> start(String path) async {
    lastPath = path;
  }

  @override
  Future<RecordedClip?> stop() async {
    final path = lastPath;
    if (path == null) return null;
    return RecordedClip(path: path, sizeBytes: 2048);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> discard(String path) async {}

  @override
  void dispose() {}
}

/// A queue fake that behaves like the real one from the UI's seat: enqueued
/// messages show as waiting bubbles with the live stage line, and
/// [complete] lands the finished turn in the transcript like the job
/// watcher would (the real delivery path is covered by
/// `async_voice_queue_test.dart`).
class _FakeQueue extends AsyncVoiceQueue {
  _FakeQueue(this.store);

  final TranscriptStore store;
  final delivered = <String>[];
  final live = <QueuedVoiceMessage>[];
  final statuses = <String, String>{};

  @override
  List<QueuedVoiceMessage> get items => List.unmodifiable(live);

  @override
  List<QueuedVoiceMessage> get waiting => List.unmodifiable(live);

  @override
  Map<String, String> get jobStatuses => Map.unmodifiable(statuses);

  @override
  Future<void> activate() async {}

  @override
  Future<QueuedVoiceMessage> enqueue(String jobId, File file) async {
    delivered.add(jobId);
    final m = QueuedVoiceMessage(
      jobId: jobId,
      fileName: 'x.wav',
      createdAt: DateTime.now(),
    );
    live.add(m);
    notifyListeners();
    return m;
  }

  @override
  Future<void> cancel(String jobId) async {
    live.removeWhere((m) => m.jobId == jobId);
    notifyListeners();
  }

  void complete(
    String jobId, {
    required String transcript,
    required String reply,
    required String replyAudioUrl,
  }) {
    store.addTurn(
      TurnRole.user,
      transcript,
      TurnSource.voice,
      audioUrl: 'https://cdn.example/u.wav',
    );
    store.addTurn(
      TurnRole.ayma,
      reply,
      TurnSource.voice,
      audioUrl: replyAudioUrl,
    );
    live.removeWhere((m) => m.jobId == jobId);
    statuses.remove(jobId);
    notifyListeners();
  }
}

class _FakePlayer implements AsyncVoicePlayer {
  final playedUrls = <String>[];
  final playedFiles = <String>[];
  final _playing = ValueNotifier<bool>(false);

  @override
  Future<void> playUrl(String url) async {
    playedUrls.add(url);
    _playing.value = true;
  }

  @override
  Future<void> playFile(String path) async {
    playedFiles.add(path);
    _playing.value = true;
  }

  @override
  Future<void> stop() async {
    _playing.value = false;
  }

  @override
  ValueListenable<bool> get playing => _playing;

  @override
  void dispose() {
    _playing.dispose();
  }
}

Future<ApiClient> _api() async {
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') {
      return http.Response(
        jsonEncode({'messages': <dynamic>[], 'next_before': null}),
        200,
        headers: _json,
      );
    }
    return http.Response('{}', 200, headers: _json);
  });
  return ApiClient(
    httpClient: mockHttp,
    auth: MockFirebaseAuth(signedIn: true),
  );
}

void main() {
  testWidgets('hold the mic speaks a voice message into the thread', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = TranscriptStore();
    final voice = _FakeVoice();
    final queue = _FakeQueue(store);
    final recorder = _FakeRecorder();
    final controller = AsyncVoiceController(recorder: recorder, queue: queue);
    final player = _FakePlayer();
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);
    addTearDown(player.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: ChatScreen(
          apiClient: await _api(),
          voiceController: voice,
          transcriptStore: store,
          asyncVoiceController: controller,
          asyncVoiceQueue: queue,
          asyncVoicePlayer: player,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Press and hold the composer's mic: the recording bar appears, and no
    // live call starts (tap path untouched).
    final mic = find.byIcon(Icons.mic_none_rounded);
    expect(mic, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.state, AsyncVoiceUiState.recording);
    expect(voice.phase, VoiceSessionPhase.idle);
    expect(find.text('Release to send'), findsOneWidget);

    // Release: the message queues as a waiting bubble with the live stage.
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(queue.delivered, hasLength(1));
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('Sending your voice…'), findsOneWidget);

    // The cloud finishes: both turns land in the thread, playable.
    queue.complete(
      queue.delivered.first,
      transcript: 'book me a table',
      reply: 'done, see you at eight',
      replyAudioUrl: 'https://cdn.example/r.wav',
    );
    await tester.pump();
    expect(find.text('book me a table'), findsOneWidget);
    expect(find.text('done, see you at eight'), findsOneWidget);
    expect(find.text('Voice message'), findsNWidgets(2));

    // Tapping a play row plays that turn's clip, and only one at a time.
    await tester.tap(find.text('Voice message').first);
    await tester.pump();
    expect(player.playedUrls, ['https://cdn.example/u.wav']);
  });

  testWidgets('a call that cannot connect offers the voice-message fallback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = TranscriptStore();
    final voice = _FakeVoice()..failNextStart = true;
    final queue = _FakeQueue(store);
    final controller = AsyncVoiceController(
      recorder: _FakeRecorder(),
      queue: queue,
    );
    final player = _FakePlayer();
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);
    addTearDown(player.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: ChatScreen(
          apiClient: await _api(),
          voiceController: voice,
          transcriptStore: store,
          asyncVoiceController: controller,
          asyncVoiceQueue: queue,
          asyncVoicePlayer: player,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic_none_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(voice.phase, VoiceSessionPhase.error);

    // The honest error carries the fallback action, which opens the sheet.
    expect(
      find.text('Could not reach Ayma. Check your connection.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Voice message'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hold the button'), findsOneWidget);
  });

  testWidgets('a denied mic on hold explains instead of hanging', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = TranscriptStore();
    final queue = _FakeQueue(store);
    final controller = AsyncVoiceController(
      recorder: _FakeRecorder()..allowed = false,
      queue: queue,
    );
    final player = _FakePlayer();
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);
    addTearDown(player.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: ChatScreen(
          apiClient: await _api(),
          voiceController: _FakeVoice(),
          transcriptStore: store,
          asyncVoiceController: controller,
          asyncVoiceQueue: queue,
          asyncVoicePlayer: player,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mic = find.byIcon(Icons.mic_none_rounded);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();
    expect(find.textContaining('Microphone'), findsOneWidget);
    expect(queue.delivered, isEmpty);
    expect(find.text('Release to send'), findsNothing);
  });
}
