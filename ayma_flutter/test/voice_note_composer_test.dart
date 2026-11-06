import 'dart:async';
import 'dart:io';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/async_voice_player.dart';
import 'package:ayma_flutter/services/async_voice_recorder.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/dm_voice_engine.dart';
import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:ayma_flutter/services/voice_note_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:ayma_flutter/widgets/voice_note_composer.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A [VoiceNoteEngine] double: records every call, no microphone, no IO.
class _FakeEngine extends VoiceNoteEngine {
  bool recording = false;
  bool paused = false;
  bool allowStart = true;
  int starts = 0;
  int sends = 0;
  int cancels = 0;
  int pauses = 0;
  int resumes = 0;
  String? _error;

  @override
  bool get isRecording => recording;
  @override
  bool get isPaused => paused;
  @override
  Duration get elapsed => const Duration(seconds: 3);
  @override
  Duration get maxClipDuration => const Duration(seconds: 120);
  @override
  String? takeError() {
    final e = _error;
    _error = null;
    return e;
  }

  @override
  Future<bool> startRecording() async {
    starts++;
    if (!allowStart) {
      _error = 'denied';
      notifyListeners();
      return false;
    }
    recording = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> sendRecording() async {
    sends++;
    recording = false;
    paused = false;
    notifyListeners();
  }

  @override
  Future<void> cancelRecording() async {
    cancels++;
    recording = false;
    paused = false;
    notifyListeners();
  }

  @override
  Future<void> pauseRecording() async {
    pauses++;
    paused = true;
    notifyListeners();
  }

  @override
  Future<void> resumeRecording() async {
    resumes++;
    paused = false;
    notifyListeners();
  }
}

class _FakeRecorder implements AsyncVoiceRecorder {
  bool allowed = true;
  String? lastPath;
  int cancels = 0;

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
    return RecordedClip(path: path, sizeBytes: 4096);
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> discard(String path) async {}

  @override
  void dispose() {}
}

class _FakePlayer implements AsyncVoicePlayer {
  final playedFiles = <String>[];
  final _playing = ValueNotifier<bool>(false);

  @override
  Future<void> playUrl(String url) async => _playing.value = true;

  @override
  Future<void> playFile(String path) async {
    playedFiles.add(path);
    _playing.value = true;
  }

  @override
  Future<void> stop() async => _playing.value = false;

  @override
  ValueListenable<bool> get playing => _playing;

  @override
  void dispose() => _playing.dispose();
}

void main() {
  group('composer mic/send swap (WhatsApp model)', () {
    Widget harness({
      required TextEditingController controller,
      required bool canSend,
      VoiceNoteController? note,
    }) {
      final level = ValueNotifier<double>(0);
      return MaterialApp(
        theme: AymaTheme.light,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              mode: ComposerMode.text,
              controller: controller,
              focusNode: FocusNode(),
              canSend: canSend,
              onSend: () {},
              onAttach: () {},
              onMicPressed: () {},
              onStopPressed: () {},
              onMuteTap: () {},
              muted: false,
              userAmplitude: level,
              aiAmplitude: level,
              voiceNoteController: note,
            ),
          ),
        ),
      );
    }

    testWidgets('empty input shows the mic, no send button', (tester) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      final controller = TextEditingController();
      await tester.pumpWidget(
        harness(controller: controller, canSend: false, note: note),
      );
      await tester.pump();
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('composerSendButton')), findsNothing);
    });

    testWidgets('typing swaps mic to send; clearing swaps back', (
      tester,
    ) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      final controller = TextEditingController();
      await tester.pumpWidget(
        harness(controller: controller, canSend: false, note: note),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(find.byKey(const ValueKey('composerSendButton')), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);

      controller.clear();
      await tester.pump();
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('composerSendButton')), findsNothing);
    });

    testWidgets('a staged attachment (canSend) shows send with empty text', (
      tester,
    ) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      final controller = TextEditingController();
      await tester.pumpWidget(
        harness(controller: controller, canSend: true, note: note),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('composerSendButton')), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    });
  });

  group('voice-note recording state machine', () {
    Widget harness(VoiceNoteController note) {
      return MaterialApp(
        theme: AymaTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              VoiceNoteRecordingBar(controller: note),
              VoiceNoteMicButton(
                controller: note,
                background: Colors.grey.shade800,
                foreground: Colors.white,
              ),
            ],
          ),
        ),
      );
    }

    Future<TestGesture> holdMic(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.mic_none_rounded)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      return gesture;
    }

    testWidgets('hold records; release sends', (tester) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      expect(engine.starts, 1);
      expect(note.phase, VoiceNotePhase.holding);
      expect(
        find.byKey(const ValueKey('voiceNoteRecordingBar')),
        findsOneWidget,
      );
      expect(find.text('Release to send'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(engine.sends, 1);
      expect(engine.cancels, 0);
      expect(note.phase, VoiceNotePhase.idle);
    });

    testWidgets('slide left arms cancel; release discards, nothing sent', (
      tester,
    ) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(note.cancelArmed, isTrue);
      expect(find.text('Release to cancel'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(engine.cancels, 1);
      expect(engine.sends, 0);
      expect(note.phase, VoiceNotePhase.idle);
    });

    testWidgets('sliding back out of the cancel zone disarms it', (
      tester,
    ) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(note.cancelArmed, isTrue);
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(note.cancelArmed, isFalse);
      await gesture.up();
      await tester.pump();
      expect(engine.sends, 1);
      expect(engine.cancels, 0);
    });

    testWidgets('slide up locks; release keeps recording hands-free', (
      tester,
    ) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(note.phase, VoiceNotePhase.locked);
      await gesture.up();
      await tester.pump();
      expect(engine.isRecording, isTrue);
      expect(engine.sends, 0);
      expect(find.text('Recording'), findsOneWidget);
      // Locked send control sends it.
      await tester.tap(find.byKey(const ValueKey('voiceNoteSendButton')));
      await tester.pump();
      expect(engine.sends, 1);
      expect(note.phase, VoiceNotePhase.idle);
    });

    testWidgets('locked delete discards, nothing sent', (tester) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voiceNoteDeleteButton')));
      await tester.pump();
      expect(engine.cancels, 1);
      expect(engine.sends, 0);
      expect(note.phase, VoiceNotePhase.idle);
    });

    testWidgets('locked pause and resume toggle the engine', (tester) async {
      final engine = _FakeEngine();
      final note = VoiceNoteController(engine: engine);
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voiceNotePauseButton')));
      await tester.pump();
      expect(engine.pauses, 1);
      expect(engine.isPaused, isTrue);
      expect(find.text('Paused'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voiceNotePauseButton')));
      await tester.pump();
      expect(engine.resumes, 1);
      expect(engine.isPaused, isFalse);
    });

    testWidgets('a refused hold (gate) never starts recording', (tester) async {
      final engine = _FakeEngine();
      var refused = 0;
      final note = VoiceNoteController(
        engine: engine,
        canStart: () => false,
        onStartRefused: () => refused++,
      );
      addTearDown(note.dispose);
      addTearDown(engine.dispose);
      await tester.pumpWidget(harness(note));
      final gesture = await holdMic(tester);
      expect(refused, 1);
      expect(engine.starts, 0);
      expect(note.phase, VoiceNotePhase.idle);
      await gesture.up();
      await tester.pump();
      expect(engine.sends, 0);
    });
  });

  group('DmVoiceNoteEngine', () {
    test(
      'send delivers the clip to onSendClip; cancel delivers nothing',
      () async {
        final recorder = _FakeRecorder();
        final sent = <File>[];
        final engine = DmVoiceNoteEngine(
          recorder: recorder,
          onSendClip: (f) async => sent.add(f),
        );
        addTearDown(engine.dispose);

        expect(await engine.startRecording(), isTrue);
        expect(engine.isRecording, isTrue);
        await engine.sendRecording();
        expect(sent, hasLength(1));
        expect(engine.isRecording, isFalse);

        expect(await engine.startRecording(), isTrue);
        await engine.cancelRecording();
        expect(sent, hasLength(1));
        expect(recorder.cancels, 1);
      },
    );

    test('mic denied reports an error and stays idle', () async {
      final recorder = _FakeRecorder()..allowed = false;
      final engine = DmVoiceNoteEngine(
        recorder: recorder,
        onSendClip: (_) async {},
      );
      addTearDown(engine.dispose);
      expect(await engine.startRecording(), isFalse);
      expect(engine.isRecording, isFalse);
      expect(engine.takeError(), contains('Microphone'));
    });
  });

  group('DM thread composer (founder screenshot regression)', () {
    testWidgets(
      'mic shows by default; hold records; release sends a voice DM and '
      'the playable bubble appears immediately',
      (tester) async {
        tester.view.physicalSize = const Size(600, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final ctrl = StreamController<List<DmMessage>>.broadcast();
        final dm = _FakeDm(ctrl);
        final recorder = _FakeRecorder();
        final player = _FakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            theme: AymaTheme.light,
            home: DmThreadScreen(
              threadId: 'a__me',
              dmService: dm,
              apiClient: _api(),
              voiceNoteRecorder: recorder,
              voicePlayer: player,
            ),
          ),
        );
        ctrl.add(const []);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // The founder's screenshot had NO mic at all - it must be there,
        // and no send button while the input is empty.
        expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
        expect(find.byKey(const ValueKey('composerSendButton')), findsNothing);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byIcon(Icons.mic_none_rounded)),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          find.byKey(const ValueKey('voiceNoteRecordingBar')),
          findsOneWidget,
        );
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Uploaded + posted as a voice DM, and the sender's playable
        // bubble is already on screen from the local file.
        expect(dm.voiceUploads, 1);
        expect(dm.voiceSent, ['uploads/me/dm/a__me/voice_1.wav']);
        expect(find.text('Voice message'), findsOneWidget);
      },
    );
  });
}

ApiClient _api() {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      return http.Response('{}', 200);
    }),
  );
}

class _FakeDm extends DmService {
  _FakeDm(this._msgs)
    : super(
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      );

  final StreamController<List<DmMessage>> _msgs;
  int voiceUploads = 0;
  final List<String> voiceSent = [];

  @override
  Stream<List<DmMessage>> watchMessages(String threadId, {int limit = 30}) =>
      _msgs.stream;

  @override
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(
    String threadId, {
    int limit = 30,
  }) => _msgs.stream.map((m) => FreshData(data: m));

  @override
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) async =>
      DmAssist.empty;

  @override
  Future<void> markThreadRead(String threadId) async {}

  @override
  Future<DmAttachment> uploadVoiceClip(
    File file, {
    required String threadId,
  }) async {
    voiceUploads++;
    return const DmAttachment(
      storagePath: 'uploads/me/dm/a__me/voice_1.wav',
      downloadUrl: 'https://example.com/voice_1.wav',
      contentType: 'audio/wav',
      sizeBytes: 4096,
      name: 'voice_1.wav',
    );
  }

  @override
  Future<void> sendVoice(String threadId, String storagePath) async {
    voiceSent.add(storagePath);
  }

  @override
  Future<String?> voiceDownloadUrl(String storagePath) async =>
      'https://example.com/clip.wav';
}
