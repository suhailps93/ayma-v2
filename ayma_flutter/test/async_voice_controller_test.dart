// The error-Firestore fake below implements the sealed DocumentReference
// to make snapshots() fail on demand; there is no composable way to do
// that in a unit test.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:io';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/async_voice_controller.dart';
import 'package:ayma_flutter/services/async_voice_queue.dart';
import 'package:ayma_flutter/services/async_voice_recorder.dart';
import 'package:ayma_flutter/services/connection_heartbeat.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRecorder implements AsyncVoiceRecorder {
  bool allowed = true;
  bool throwOnStart = false;
  int sizeBytes = 2048;
  bool returnNullOnStop = false;

  /// When true, start() writes a real clip file — needed when the test
  /// drives the real queue, which moves the recorded file into its clips
  /// directory on enqueue.
  bool writeFile = false;
  String? startedPath;
  bool stopped = false;
  bool cancelled = false;
  bool disposed = false;
  final discarded = <String>[];

  @override
  Future<bool> ensurePermission() async => allowed;

  @override
  Future<void> start(String path) async {
    if (throwOnStart) throw StateError('mic busy');
    startedPath = path;
    if (writeFile) await File(path).writeAsBytes(List.filled(2048, 0));
  }

  @override
  Future<RecordedClip?> stop() async {
    stopped = true;
    final path = startedPath;
    if (path == null || returnNullOnStop) return null;
    return RecordedClip(path: path, sizeBytes: sizeBytes);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> discard(String path) async {
    discarded.add(path);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class _FakeQueue extends AsyncVoiceQueue {
  final delivered = <String>[];
  final live = <QueuedVoiceMessage>[];

  @override
  List<QueuedVoiceMessage> get items => List.unmodifiable(live);

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

  void finish(String jobId) {
    live.removeWhere((m) => m.jobId == jobId);
    notifyListeners();
  }
}

void main() {
  test('press records, release sends, completion idles', () async {
    final recorder = _FakeRecorder();
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(recorder: recorder, queue: queue);
    addTearDown(controller.dispose);

    expect(await controller.startRecording(), isTrue);
    expect(controller.state, AsyncVoiceUiState.recording);
    expect(controller.activeJobId, startsWith('v-'));
    expect(recorder.startedPath, endsWith('.wav'));

    // A second press while busy is refused.
    expect(await controller.startRecording(), isFalse);

    await controller.stopAndSend();
    expect(recorder.stopped, isTrue);
    expect(queue.delivered, [controller.activeJobId]);
    expect(controller.state, AsyncVoiceUiState.working);

    queue.finish(controller.activeJobId!);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, AsyncVoiceUiState.idle);
    expect(controller.activeJobId, isNull);
  });

  test('a too-short tap records nothing and sends nothing', () async {
    final recorder = _FakeRecorder()..sizeBytes = 3;
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(recorder: recorder, queue: queue);
    addTearDown(controller.dispose);

    expect(await controller.startRecording(), isTrue);
    await controller.stopAndSend();
    expect(queue.delivered, isEmpty);
    expect(recorder.discarded, hasLength(1));
    expect(controller.state, AsyncVoiceUiState.idle);
    expect(controller.takeError(), isNull);
  });

  test('a stop that yields no clip idles without queueing', () async {
    final recorder = _FakeRecorder()..returnNullOnStop = true;
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(recorder: recorder, queue: queue);
    addTearDown(controller.dispose);

    expect(await controller.startRecording(), isTrue);
    await controller.stopAndSend();
    expect(queue.delivered, isEmpty);
    expect(controller.state, AsyncVoiceUiState.idle);
  });

  test('a denied mic fails honestly and stays idle', () async {
    final recorder = _FakeRecorder()..allowed = false;
    final controller = AsyncVoiceController(
      recorder: recorder,
      queue: _FakeQueue(),
    );
    addTearDown(controller.dispose);

    expect(await controller.startRecording(), isFalse);
    expect(controller.state, AsyncVoiceUiState.idle);
    expect(controller.takeError(), contains('Microphone'));
    expect(controller.takeError(), isNull); // one-shot
  });

  test('a recorder that will not start fails honestly', () async {
    final recorder = _FakeRecorder()..throwOnStart = true;
    final controller = AsyncVoiceController(
      recorder: recorder,
      queue: _FakeQueue(),
    );
    addTearDown(controller.dispose);

    expect(await controller.startRecording(), isFalse);
    expect((controller.takeError() ?? ''), isNotEmpty);
  });

  test('cancel drops the recording without queueing', () async {
    final recorder = _FakeRecorder();
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(recorder: recorder, queue: queue);
    addTearDown(controller.dispose);

    expect(await controller.startRecording(), isTrue);
    await controller.cancelRecording();
    expect(recorder.cancelled, isTrue);
    expect(queue.delivered, isEmpty);
    expect(controller.state, AsyncVoiceUiState.idle);

    // Cancelling while idle is a no-op.
    await controller.cancelRecording();
    await controller.stopAndSend();
    expect(queue.delivered, isEmpty);
  });

  test('dispose releases the recorder', () async {
    final recorder = _FakeRecorder();
    final controller = AsyncVoiceController(
      recorder: recorder,
      queue: _FakeQueue(),
    );
    await controller.startRecording();
    controller.dispose();
    expect(recorder.disposed, isTrue);
  });

  test(
    'regression (note 110): a second send works after the first completes '
    'through the reconcile path',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('avc-110');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = TranscriptStore();
      final api = _FakeApi();
      final queue = AsyncVoiceQueue(
        api: api,
        store: store,
        sessionId: 's-1',
        currentUid: () => 'u1',
        uploader: _FakeUploader(),
        firestore: _ErrorFirestore(),
        heartbeat: ConnectionHeartbeat(
          probe: () async => ProbeOutcome.good,
          connectivityChanges: const Stream.empty(),
        ),
        clipsDir: () async => dir,
        watchRetryDelay: const Duration(milliseconds: 100),
      );
      addTearDown(queue.dispose);
      await queue.activate();

      final recorder = _FakeRecorder()..writeFile = true;
      final controller = AsyncVoiceController(recorder: recorder, queue: queue);
      addTearDown(controller.dispose);

      // Send #1: the submit is accepted, then the job watch dies
      // (permission-denied) — the reconcile path must deliver it.
      expect(await controller.startRecording(), isTrue);
      final job1 = controller.activeJobId!;
      await controller.stopAndSend();
      expect(controller.state, AsyncVoiceUiState.working);
      await _eventually(() => api.submits.contains(job1), 'the first submit');
      // Let the watch error land and the reconcile timer arm.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      api.answer = (jobId) => VoiceAsyncSubmit(
        jobId: jobId,
        status: 'done',
        transcript: 'A fine question.',
        replyText: 'Here is my answer.',
        replyAudioUrl: 'https://cdn.example/r.wav',
      );
      await _eventually(
        () => controller.state == AsyncVoiceUiState.idle,
        'the controller to idle after the reconcile',
      );
      expect(queue.jobStatuses, isEmpty);
      expect(queue.isEmpty, isTrue);
      expect(
        store.turns.map((t) => t.text).toList(),
        ['A fine question.', 'Here is my answer.'],
      );

      // Send #2 in the same session: before the fix, startRecording
      // silently returned false here — the controller never left `working`
      // because the reconcile removal left the job's status behind.
      expect(await controller.startRecording(), isTrue);
      final job2 = controller.activeJobId!;
      expect(job2, isNot(job1));
      api.answer = (jobId) => VoiceAsyncSubmit(
        jobId: jobId,
        status: 'done',
        transcript: 'One more thing.',
        replyText: 'Second answer.',
        replyAudioUrl: 'https://cdn.example/r2.wav',
      );
      await controller.stopAndSend();
      await _eventually(
        () => controller.state == AsyncVoiceUiState.idle,
        'the controller to idle after the second send',
      );
      expect(queue.jobStatuses, isEmpty);
      expect(queue.isEmpty, isTrue);
      expect(api.submits, contains(job2));
      expect(
        store.turns.map((t) => t.text).toList(),
        [
          'A fine question.',
          'Here is my answer.',
          'One more thing.',
          'Second answer.',
        ],
      );
    },
  );

  test(
    'regression (note 111): restored offline job reconciles in-session when '
    'first reconcile observes non-terminal phase and later completes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('avc-111-restore');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = TranscriptStore();
      final api = _FakeApi();
      final hb = _FakeHeartbeat(initial: ConnectionQuality.offline);
      final queue = AsyncVoiceQueue(
        api: api,
        store: store,
        sessionId: 's-1',
        currentUid: () => 'u1',
        uploader: _FakeUploader(),
        firestore: _FailOnceFirestore(),
        heartbeat: hb,
        clipsDir: () async => dir,
        watchRetryDelay: const Duration(milliseconds: 50),
      );
      addTearDown(queue.dispose);
      await queue.activate();

      final recorder = _FakeRecorder()..writeFile = true;
      final controller = AsyncVoiceController(recorder: recorder, queue: queue);
      addTearDown(controller.dispose);

      // Record offline: submitted is false, nothing submitted yet.
      expect(await controller.startRecording(), isTrue);
      final jobId = controller.activeJobId!;
      await controller.stopAndSend();
      expect(controller.state, AsyncVoiceUiState.working);
      expect(api.submits, isEmpty);
      expect(queue.items.map((m) => m.jobId), [jobId]);

      // Server is in 'speaking' phase when submit arrives.
      api.answer = (id) => VoiceAsyncSubmit(
        jobId: id,
        status: 'speaking',
      );

      // Restore connection: trigger flush.
      hb.change(ConnectionQuality.ok);

      // Job is submitted; the watch fails; first reconcile observes
      // non-terminal phase ('speaking').
      await _eventually(
        () => api.submits.contains(jobId),
        'the first submit after restore',
      );
      // Wait long enough for the first reconcile to observe 'speaking'.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The job later completes server-side.
      api.answer = (id) => VoiceAsyncSubmit(
        jobId: id,
        status: 'done',
        transcript: 'Yes, offline question.',
        replyText: 'Online answer.',
        replyAudioUrl: 'https://cdn.example/ans.wav',
      );

      // Reconcile must re-check and adopt the done job in-session without relaunch.
      await _eventually(
        () => controller.state == AsyncVoiceUiState.idle,
        'the controller to idle after re-armed reconcile',
      );
      expect(queue.jobStatuses, isEmpty);
      expect(queue.isEmpty, isTrue);
      expect(
        store.turns.map((t) => t.text).toList(),
        ['Yes, offline question.', 'Online answer.'],
      );
    },
  );

  test(
    'regression (note 111): while a restored job sits unreconciled, '
    'startRecording() for a new send succeeds (not wedged)',
    () async {
      SharedPreferences.setMockInitialValues({
        'async_voice_queue_v1:u1':
            '[{"id":"v-offline","file":"v-offline.wav","storage_path":"uploads/u1/v-offline.wav","submitted":true,"created_at":"2026-11-05T21:00:00.000Z"}]',
      });
      final dir = await Directory.systemTemp.createTemp('avc-111-unwedged');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      // Create clip file on disk so the loaded queue item is kept.
      final clipsDir = Directory('${dir.path}/async_voice_clips');
      await clipsDir.create(recursive: true);
      await File('${clipsDir.path}/v-offline.wav')
          .writeAsBytes(List.filled(2048, 0));

      final store = TranscriptStore();
      final api = _FakeApi();
      final queue = AsyncVoiceQueue(
        api: api,
        store: store,
        sessionId: 's-1',
        currentUid: () => 'u1',
        uploader: _FakeUploader(),
        firestore: _ErrorFirestore(),
        heartbeat: ConnectionHeartbeat(
          probe: () async => ProbeOutcome.good,
          connectivityChanges: const Stream.empty(),
        ),
        clipsDir: () async => dir,
        watchRetryDelay: const Duration(milliseconds: 50),
      );
      addTearDown(queue.dispose);
      await queue.activate();

      // The restored job is unreconciled in the queue (e.g. server still processing).
      api.answer = (id) => VoiceAsyncSubmit(jobId: id, status: 'speaking');
      expect(queue.items.map((m) => m.jobId), contains('v-offline'));

      // A controller starts: it must not wedge on startRecording().
      final recorder = _FakeRecorder()..writeFile = true;
      final controller = AsyncVoiceController(recorder: recorder, queue: queue);
      addTearDown(controller.dispose);

      expect(controller.state, AsyncVoiceUiState.idle);
      expect(await controller.startRecording(), isTrue);
      expect(controller.state, AsyncVoiceUiState.recording);
      expect(controller.activeJobId, isNot('v-offline'));
    },
  );
}

class _FailOnceFirestore extends Fake implements FirebaseFirestore {
  int watchAttempts = 0;

  @override
  DocumentReference<Map<String, dynamic>> doc(String path) =>
      _FailOnceDocRef(this);
}

class _FailOnceDocRef extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _FailOnceDocRef(this.store);
  final _FailOnceFirestore store;

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) {
    store.watchAttempts++;
    if (store.watchAttempts == 1) {
      return Stream.error(
        FirebaseException(plugin: 'firestore', code: 'permission-denied'),
      );
    }
    // Subsequent watch does not deliver events (hung/silent live watch).
    return const Stream.empty();
  }
}

class _FakeHeartbeat extends Fake implements ConnectionHeartbeat {
  _FakeHeartbeat({ConnectionQuality initial = ConnectionQuality.ok})
    : notifier = ValueNotifier(initial);

  final ValueNotifier<ConnectionQuality> notifier;

  @override
  ValueListenable<ConnectionQuality> get listenable => notifier;

  @override
  ConnectionQuality get state => notifier.value;

  void change(ConnectionQuality q) {
    notifier.value = q;
  }
}

Future<void> _eventually(bool Function() cond, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeUploader implements AsyncVoiceUploader {
  final uploads = <String>[];

  @override
  Future<void> upload(String storagePath, File file) async {
    uploads.add(storagePath);
  }

  @override
  Future<String?> downloadUrl(String storagePath) async => null;
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final submits = <String>[];
  VoiceAsyncSubmit Function(String jobId) answer = (jobId) =>
      VoiceAsyncSubmit(jobId: jobId, status: 'received');

  @override
  Future<VoiceAsyncSubmit> submitVoiceMessage({
    required String jobId,
    required String storagePath,
    String sessionId = '',
    List<Map<String, String>> recentTurns = const [],
  }) async {
    submits.add(jobId);
    return answer(jobId);
  }
}

/// A Firestore whose every doc watch errors immediately — the live
/// failure behind Scout note 109 (the job-doc stream answered
/// permission-denied, so the client never heard the job finish).
class _ErrorDocRef extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource? source,
  }) => Stream.error(
    FirebaseException(plugin: 'firestore', code: 'permission-denied'),
  );
}

class _ErrorFirestore extends Fake implements FirebaseFirestore {
  @override
  DocumentReference<Map<String, dynamic>> doc(String path) => _ErrorDocRef();
}
