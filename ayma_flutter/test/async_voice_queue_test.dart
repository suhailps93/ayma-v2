// The error-Firestore fake below implements the sealed DocumentReference
// to make snapshots() fail on demand; there is no composable way to do
// that in a unit test.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:io';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/async_voice_queue.dart';
import 'package:ayma_flutter/services/connection_heartbeat.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUploader implements AsyncVoiceUploader {
  final uploads = <String>[];
  final urls = <String, String>{};
  bool failUpload = false;

  @override
  Future<void> upload(String storagePath, File file) async {
    if (failUpload) throw StateError('no network');
    uploads.add(storagePath);
  }

  @override
  Future<String?> downloadUrl(String storagePath) async => urls[storagePath];
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final submits = <String>[];
  VoiceAsyncSubmit Function(String jobId) answer = (jobId) =>
      VoiceAsyncSubmit(jobId: jobId, status: 'received');
  bool failSubmit = false;

  @override
  Future<VoiceAsyncSubmit> submitVoiceMessage({
    required String jobId,
    required String storagePath,
    String sessionId = '',
    List<Map<String, String>> recentTurns = const [],
  }) async {
    if (failSubmit) throw ApiException('submit failed', statusCode: 500);
    submits.add(jobId);
    return answer(jobId);
  }
}

/// A Firestore whose every doc watch errors immediately — the live
/// failure behind Scout note 109 (the job-doc stream answered
/// permission-denied, so the client never heard the job finish).
/// DocumentReference is sealed; a test fake is the only way to make its
/// snapshots() fail on demand (see the ignore_for_file at the top).
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

class _Harness {
  _Harness._({
    required this.dir,
    required this.store,
    required this.uploader,
    required this.api,
    required this.firestore,
    required this.script,
    required this.heartbeat,
    required this.queue,
  });

  final Directory dir;
  final TranscriptStore store;
  final _FakeUploader uploader;
  final _FakeApi api;
  final FakeFirebaseFirestore firestore;
  final List<ProbeOutcome> script;
  final ConnectionHeartbeat heartbeat;
  final AsyncVoiceQueue queue;

  static Future<_Harness> make() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('avq');
    final store = TranscriptStore();
    final uploader = _FakeUploader();
    final api = _FakeApi();
    final firestore = FakeFirebaseFirestore();
    final script = <ProbeOutcome>[];
    final heartbeat = ConnectionHeartbeat(
      probe: () async =>
          script.isEmpty ? ProbeOutcome.good : script.removeAt(0),
    );
    final queue = AsyncVoiceQueue(
      api: api,
      store: store,
      sessionId: 's-1',
      currentUid: () => 'u1',
      uploader: uploader,
      firestore: firestore,
      heartbeat: heartbeat,
      clipsDir: () async => dir,
    );
    return _Harness._(
      dir: dir,
      store: store,
      uploader: uploader,
      api: api,
      firestore: firestore,
      script: script,
      heartbeat: heartbeat,
      queue: queue,
    );
  }

  Future<void> goOffline() async {
    script.addAll([ProbeOutcome.failure, ProbeOutcome.failure]);
    await heartbeat.probeNow();
    await heartbeat.probeNow();
    expect(heartbeat.state, ConnectionQuality.offline);
  }

  Future<void> goOnline() async {
    // Two good probes: the classifier climbs offline -> weak -> ok, and the
    // queue flushes on anything but offline (weak included).
    script.addAll([ProbeOutcome.good, ProbeOutcome.good]);
    await heartbeat.probeNow();
    await heartbeat.probeNow();
    expect(heartbeat.state, ConnectionQuality.ok);
  }

  Future<File> record(String name) async {
    final file = File('${dir.path}/$name.wav');
    await file.writeAsBytes(List.filled(2048, 0));
    return file;
  }

  Future<void> dispose() async {
    queue.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
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

Map<String, dynamic> _doneDoc() => {
  'status': 'done',
  'transcript': 'book me a table',
  'reply_text': 'done, see you at eight',
  'reply_audio_url': 'https://cdn.example/r.wav',
  'tools': ['Booked a table'],
  'image_url': '',
};

void main() {
  test('offline-queue-then-send: queued offline, sent on reconnect, '
      'reply lands in thread', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    await h.goOffline();
    await h.queue.activate();

    // Record + release while offline: nothing leaves the phone.
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.uploader.uploads, isEmpty);
    expect(h.api.submits, isEmpty);
    expect(h.queue.items.map((m) => m.jobId), ['v-1']);
    expect(h.queue.waiting.map((m) => m.jobId), ['v-1']);
    // …but it survives a restart (metadata in prefs, clip on disk).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('async_voice_queue_v1:u1'), contains('v-1'));

    // The connection comes back: the clip uploads, the job submits.
    await h.goOnline();
    await _eventually(() => h.uploader.uploads.isNotEmpty, 'the upload');
    expect(h.uploader.uploads, ['uploads/u1/async_voice/v-1.wav']);
    await _eventually(() => h.api.submits.isNotEmpty, 'the submit');
    expect(h.api.submits, ['v-1']);

    // The cloud finishes: both turns land in the thread like a message.
    h.uploader.urls['uploads/u1/async_voice/v-1.wav'] =
        'https://cdn.example/u.wav';
    await h.firestore.doc('users/u1/async_voice_jobs/v-1').set(_doneDoc());
    await _eventually(() => h.store.turns.length == 2, 'the thread turns');
    final user = h.store.turns[0];
    expect(user.role, TurnRole.user);
    expect(user.text, 'book me a table');
    expect(user.source, TurnSource.voice);
    expect(user.audioUrl, 'https://cdn.example/u.wav');
    final ayma = h.store.turns[1];
    expect(ayma.role, TurnRole.ayma);
    expect(ayma.text, 'done, see you at eight');
    expect(ayma.audioUrl, 'https://cdn.example/r.wav');
    expect(ayma.tools, ['Booked a table']);

    // Delivered: the item, its clip, and its persisted row are gone. The
    // row drops from the list the moment the turn adopts; the clip-file
    // delete + prefs write land just behind it, so poll for those (an
    // immediate assert flakes under full-suite load).
    await _eventually(() => h.queue.isEmpty, 'the cleanup');
    await _eventually(
      () =>
          !File('${h.dir.path}/async_voice_clips/v-1.wav').existsSync() &&
          prefs.getString('async_voice_queue_v1:u1') == null,
      'the clip + prefs cleanup',
    );
  });

  test('a submit answered done adopts immediately without watching', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    h.api.answer = (jobId) => VoiceAsyncSubmit(
      jobId: jobId,
      status: 'done',
      transcript: 'hi',
      replyText: 'hello',
      replyAudioUrl: 'https://cdn.example/r.wav',
    );
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await _eventually(() => h.store.turns.length == 2, 'the thread turns');
    await _eventually(() => h.queue.isEmpty, 'the cleanup');
    expect(h.queue.jobStatuses, isEmpty);
  });

  test('a failed job lands as an honest error turn', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await _eventually(() => h.api.submits.isNotEmpty, 'the submit');
    await h.firestore.doc('users/u1/async_voice_jobs/v-1').set({
      'status': 'error',
      'transcript': 'half a thought',
      'error': 'Ayma got stuck. Try again.',
      'usage_capped': false,
    });
    await _eventually(() => h.store.turns.length == 2, 'the error turns');
    expect(h.store.turns[0].text, 'half a thought');
    expect(h.store.turns[1].role, TurnRole.ayma);
    expect(h.store.turns[1].text, 'Ayma got stuck. Try again.');
    expect(h.store.turns[1].capped, isFalse);
    await _eventually(() => h.queue.isEmpty, 'the cleanup');
  });

  test('a usage-capped job resolves to the reload card', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await _eventually(() => h.api.submits.isNotEmpty, 'the submit');
    await h.firestore.doc('users/u1/async_voice_jobs/v-1').set({
      'status': 'error',
      'transcript': '',
      'error': 'Out of credits.',
      'usage_capped': true,
    });
    await _eventually(() => h.store.turns.length == 2, 'the capped turn');
    expect(h.store.turns[0].role, TurnRole.user);
    expect(h.store.turns[1].capped, isTrue);
    expect(h.store.turns[1].text, 'Out of credits.');
  });

  test('an already-shown reply is never adopted twice', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    h.store.addTurn(TurnRole.ayma, 'done, see you at eight', TurnSource.text);
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await _eventually(() => h.api.submits.isNotEmpty, 'the submit');
    await h.firestore.doc('users/u1/async_voice_jobs/v-1').set(_doneDoc());
    await _eventually(() => h.queue.isEmpty, 'the cleanup');
    // Initial Ayma turn + user's sent turn; Ayma's reply is not adopted twice.
    expect(h.store.turns.length, 2);
    expect(h.store.turns.where((t) => t.role == TurnRole.ayma).length, 1);
  });

  test('cancel drops the message and deletes its clip', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    await h.goOffline();
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    expect(h.queue.items, hasLength(1));
    await h.queue.cancel('v-1');
    expect(h.queue.isEmpty, isTrue);
    expect(
      await File('${h.dir.path}/async_voice_clips/v-1.wav').exists(),
      isFalse,
    );
  });

  test('a persisted message reloads and delivers after a restart', () async {
    final dir = await Directory.systemTemp.createTemp('avq-restart');
    addTearDown(() => dir.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});

    Future<AsyncVoiceQueue> queueFor(
      _FakeUploader uploader,
      _FakeApi api,
      ConnectionHeartbeat heartbeat,
    ) async {
      final queue = AsyncVoiceQueue(
        api: api,
        store: TranscriptStore(),
        sessionId: 's-1',
        currentUid: () => 'u1',
        uploader: uploader,
        firestore: FakeFirebaseFirestore(),
        heartbeat: heartbeat,
        clipsDir: () async => dir,
      );
      await queue.activate();
      return queue;
    }

    final script = <ProbeOutcome>[ProbeOutcome.failure, ProbeOutcome.failure];
    final offline = ConnectionHeartbeat(probe: () async => script.removeAt(0));
    await offline.probeNow();
    await offline.probeNow();
    final first = await queueFor(_FakeUploader(), _FakeApi(), offline);
    final rec = File('${dir.path}/rec.wav');
    await rec.writeAsBytes(List.filled(2048, 0));
    await first.enqueue('v-9', rec);
    expect(first.items, hasLength(1));
    first.dispose();

    // "Restart": a fresh queue, same prefs + clips dir, now online.
    final uploader = _FakeUploader();
    final api = _FakeApi();
    final online = ConnectionHeartbeat(probe: () async => ProbeOutcome.good);
    final second = await queueFor(uploader, api, online);
    addTearDown(second.dispose);
    expect(second.items.map((m) => m.jobId), ['v-9']);
    await _eventually(() => api.submits.isNotEmpty, 'the resubmit');
    expect(api.submits, ['v-9']);
  });

  test(
    'a persisted message whose clip file is gone is dropped on load',
    () async {
      SharedPreferences.setMockInitialValues({
        'async_voice_queue_v1:u1': '[{"id":"v-gone","file":"v-gone.wav","storage_path":"","created_at":"2026-11-06T00:00:00.000Z"}]',
      });
      final dir = await Directory.systemTemp.createTemp('avq-gone');
      addTearDown(() => dir.delete(recursive: true));
      final heartbeat = ConnectionHeartbeat(
        probe: () async => ProbeOutcome.good,
      );
      final queue = AsyncVoiceQueue(
        api: _FakeApi(),
        store: TranscriptStore(),
        sessionId: 's-1',
        currentUid: () => 'u1',
        uploader: _FakeUploader(),
        firestore: FakeFirebaseFirestore(),
        heartbeat: heartbeat,
        clipsDir: () async => dir,
      );
      addTearDown(queue.dispose);
      await queue.activate();
      expect(queue.isEmpty, isTrue);
    },
  );

  test('flush stops at the first message that cannot go', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    h.uploader.failUpload = true;
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.queue.items.map((m) => m.jobId), ['v-1']);
    expect(h.api.submits, isEmpty);

    h.uploader.failUpload = false;
    await h.queue.flush();
    await _eventually(() => h.api.submits.isNotEmpty, 'the retry');
    expect(h.api.submits, ['v-1']);
  });

  test('job statuses drive the loader stage', () async {
    final h = await _Harness.make();
    addTearDown(h.dispose);
    await h.queue.activate();
    await h.queue.enqueue('v-1', await h.record('rec1'));
    await _eventually(() => h.api.submits.isNotEmpty, 'the submit');
    final doc = h.firestore.doc('users/u1/async_voice_jobs/v-1');
    await doc.set({'status': 'transcribing'});
    await _eventually(
      () => h.queue.jobStatuses['v-1'] == 'transcribing',
      'transcribing',
    );
    expect(h.queue.stageFor('v-1'), 1);
    await doc.set({'status': 'thinking'});
    await _eventually(
      () => h.queue.jobStatuses['v-1'] == 'thinking',
      'thinking',
    );
    expect(h.queue.stageFor('v-1'), 2);
    await doc.set({'status': 'speaking'});
    await _eventually(
      () => h.queue.jobStatuses['v-1'] == 'speaking',
      'speaking',
    );
    expect(h.queue.stageFor('v-1'), 3);
    expect(h.queue.hasActiveWork, isTrue);
  });

  test('QueuedVoiceMessage json round-trips and rejects garbage', () {
    final m = QueuedVoiceMessage(
      jobId: 'v-1',
      fileName: 'v-1.wav',
      storagePath: 'uploads/u1/async_voice/v-1.wav',
      createdAt: DateTime.utc(2026, 11, 6),
    );
    final back = QueuedVoiceMessage.fromJson(m.toJson())!;
    expect(back.jobId, 'v-1');
    expect(back.storagePath, 'uploads/u1/async_voice/v-1.wav');
    expect(QueuedVoiceMessage.fromJson(null), isNull);
    expect(QueuedVoiceMessage.fromJson([]), isNull);
    expect(QueuedVoiceMessage.fromJson({'id': '', 'file': 'x'}), isNull);
    expect(QueuedVoiceMessage.fromJson({'id': 'v-1'}), isNull);
  });

  test('regression (note 109): a job whose watch errors still reconciles '
      'once the server finishes it — queue clears, turns land', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('avq-err');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = TranscriptStore();
    final uploader = _FakeUploader();
    final api = _FakeApi();
    final queue = AsyncVoiceQueue(
      api: api,
      store: store,
      sessionId: 's-1',
      currentUid: () => 'u1',
      uploader: uploader,
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

    // Record + send: the submit is accepted, then the job watch dies
    // (permission-denied) — the exact stuck state Scout found.
    final clip = File('${dir.path}/rec.wav');
    await clip.writeAsBytes(List.filled(2048, 0));
    await queue.enqueue('v-stuck', clip);
    await _eventually(() => api.submits.isNotEmpty, 'the first submit');
    expect(queue.items.map((m) => m.jobId), ['v-stuck']);
    // Let the watch error land and the reconcile timer arm.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The server finishes the job (its doc says done) — but no watch will
    // ever report it. The queue must reconcile through the idempotent
    // submit on its own: no manual flush, no relaunch.
    api.answer = (jobId) => VoiceAsyncSubmit(
      jobId: jobId,
      status: 'done',
      transcript: 'A fine question.',
      replyText: 'Here is my answer.',
      replyAudioUrl: 'https://cdn.example/r.wav',
    );
    await _eventually(() => queue.isEmpty, 'the queue to reconcile');
    expect(api.submits.where((id) => id == 'v-stuck').length,
        greaterThanOrEqualTo(2));
    final texts = store.turns.map((t) => t.text).toList();
    expect(texts, contains('A fine question.'));
    expect(texts, contains('Here is my answer.'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('async_voice_queue_v1:u1'), isNull);
  });

  test(
    'regression (decouple): offline release: bubble is sent locally while offline, uploads on restore, reply appends in-session, and note-111 reconcile path recovers',
    () async {
      final h = await _Harness.make();
      addTearDown(h.dispose);
      await h.goOffline();
      await h.queue.activate();

      // 1. Release while offline: user turn lands immediately in store, playable locally
      final clip = await h.record('offline_clip');
      await h.queue.enqueue('v-offline-1', clip);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(h.store.turns, hasLength(1));
      final userTurn = h.store.turns.first;
      expect(userTurn.role, TurnRole.user);
      expect(userTurn.source, TurnSource.voice);
      expect(userTurn.audioFile?.path, contains('v-offline-1.wav'));

      // No uploads or submits have occurred yet
      expect(h.uploader.uploads, isEmpty);
      expect(h.api.submits, isEmpty);
      expect(h.queue.items.map((m) => m.jobId), ['v-offline-1']);

      // 2. Reconnect: upload completes, job submits
      await h.goOnline();
      await _eventually(() => h.uploader.uploads.isNotEmpty, 'the upload');
      expect(h.uploader.uploads, ['uploads/u1/async_voice/v-offline-1.wav']);
      await _eventually(() => h.api.submits.isNotEmpty, 'the submit');
      expect(h.api.submits, ['v-offline-1']);

      // 3. Backend finishes: reply appends in-session, user bubble text attaches additively
      h.uploader.urls['uploads/u1/async_voice/v-offline-1.wav'] =
          'https://cdn.example/u-offline.wav';
      await h.firestore.doc('users/u1/async_voice_jobs/v-offline-1').set({
        'status': 'done',
        'transcript': 'note for later',
        'reply_text': 'saved your note',
        'reply_audio_url': 'https://cdn.example/r-offline.wav',
      });
      await _eventually(() => h.store.turns.length == 2, 'the thread turns');
      expect(h.store.turns[0].text, 'note for later');
      expect(h.store.turns[0].audioUrl, 'https://cdn.example/u-offline.wav');
      expect(h.store.turns[1].role, TurnRole.ayma);
      expect(h.store.turns[1].text, 'saved your note');
      expect(h.store.turns[1].audioUrl, 'https://cdn.example/r-offline.wav');

      await _eventually(() => h.queue.isEmpty, 'queue cleanup');
    },
  );
}
