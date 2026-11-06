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
  Future<void> start({bool forceRelayFirst = false}) async {
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
  String? get activeAymaStageLine {
    for (final m in live) {
      final status = statuses[m.jobId];
      final line = switch (status) {
        'transcribing' => 'Hearing you out…',
        'thinking' => 'Ayma is thinking…',
        'speaking' => 'Ayma is answering…',
        _ => null,
      };
      if (line != null) return line;
    }
    return null;
  }

  void setStatus(String jobId, String status) {
    statuses[jobId] = status;
    notifyListeners();
  }

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
    store.addTurn(
      TurnRole.user,
      '',
      TurnSource.voice,
      audioFile: file,
    );
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
    final userTurn = store.turns.where((t) => t.role == TurnRole.user).firstOrNull;
    if (userTurn != null) {
      store.updateTurn(
        userTurn,
        text: transcript,
        audioUrl: 'https://cdn.example/u.wav',
      );
    } else {
      store.addTurn(
        TurnRole.user,
        transcript,
        TurnSource.voice,
        audioUrl: 'https://cdn.example/u.wav',
      );
    }
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

    // Release: the clip renders in the thread immediately as the user's sent,
    // playable voice bubble (from the local file) — before upload or server processing.
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(queue.delivered, hasLength(1));
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('Sending your voice…'), findsNothing);

    // Playable locally right away:
    await tester.tap(find.text('Voice message').first);
    await tester.pump();
    expect(player.playedFiles, hasLength(1));

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

    // Tapping Ayma's play row plays her remote reply audio.
    await tester.tap(find.text('Voice message').last);
    await tester.pump();
    expect(player.playedUrls, ['https://cdn.example/r.wav']);
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

  testWidgets(
    'regression (decouple): release-to-sent: after a send, user bubble state is SENT + playable (local source) before any job status exists',
    (tester) async {
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

      final mic = find.byIcon(Icons.mic_none_rounded);
      final gesture = await tester.startGesture(tester.getCenter(mic));
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.state, AsyncVoiceUiState.recording);

      // Release mic: the clip renders in the thread immediately as sent + playable
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Delivered to queue, no job status yet exists
      expect(queue.delivered, hasLength(1));
      expect(queue.jobStatuses, isEmpty);
      expect(queue.activeAymaStageLine, isNull);

      // User bubble is in transcript store and rendered in thread
      expect(store.turns, hasLength(1));
      expect(store.turns.first.role, TurnRole.user);
      expect(store.turns.first.source, TurnSource.voice);
      expect(store.turns.first.audioFile, isNotNull);
      expect(find.text('Voice message'), findsOneWidget);

      // Playable from local file immediately
      await tester.tap(find.text('Voice message').first);
      await tester.pump();
      expect(player.playedFiles, hasLength(1));
      expect(player.playedUrls, isEmpty);
    },
  );

  testWidgets(
    'regression (decouple): background completion: job completion appends Ayma reply and does not mutate user bubble sent state; transcript attach is optional/additive only',
    (tester) async {
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

      final mic = find.byIcon(Icons.mic_none_rounded);
      final gesture = await tester.startGesture(tester.getCenter(mic));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      final userTurnBefore = store.turns.first;
      expect(userTurnBefore.role, TurnRole.user);
      expect(userTurnBefore.audioFile, isNotNull);

      // Backend progress updates Ayma stage, does not mutate user bubble
      queue.setStatus(queue.delivered.first, 'thinking');
      await tester.pump();
      expect(find.text('Ayma is thinking…'), findsOneWidget);
      expect(store.turns.first.audioFile, userTurnBefore.audioFile);

      // Job completion lands Ayma reply and additively attaches transcript
      queue.complete(
        queue.delivered.first,
        transcript: 'remind me tomorrow',
        reply: 'reminder set for tomorrow',
        replyAudioUrl: 'https://cdn.example/reply.wav',
      );
      await tester.pump();

      expect(store.turns, hasLength(2));
      final userTurnAfter = store.turns[0];
      final aymaTurn = store.turns[1];

      // User bubble is still SENT at index 0, same role, transcript attached additively
      expect(userTurnAfter.role, TurnRole.user);
      expect(userTurnAfter.text, 'remind me tomorrow');
      expect(userTurnAfter.source, TurnSource.voice);
      expect(userTurnAfter.audioFile, userTurnBefore.audioFile);

      // Ayma reply appended
      expect(aymaTurn.role, TurnRole.ayma);
      expect(aymaTurn.text, 'reminder set for tomorrow');
      expect(aymaTurn.audioUrl, 'https://cdn.example/reply.wav');
      expect(find.text('remind me tomorrow'), findsOneWidget);
      expect(find.text('reminder set for tomorrow'), findsOneWidget);
    },
  );

  testWidgets(
    'regression (decouple): no-holdover: no user-bubble state named or behaving as sending until processed remains in async voice path',
    (tester) async {
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

      final mic = find.byIcon(Icons.mic_none_rounded);
      final gesture = await tester.startGesture(tester.getCenter(mic));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      final jobId = queue.delivered.first;
      queue.setStatus(jobId, 'transcribing');
      await tester.pump();

      // No sending state on the user's bubble
      expect(find.text('Sending your voice…'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);

      // "Hearing you out…" surfaces ONLY as Ayma-side progress line, NOT on user bubble
      expect(find.byKey(const ValueKey('ayma-voice-progress')), findsOneWidget);
      expect(find.text('Hearing you out…'), findsOneWidget);

      // User bubble remains fully playable locally during processing
      await tester.tap(find.text('Voice message').first);
      await tester.pump();
      expect(player.playedFiles, hasLength(1));
    },
  );
}
