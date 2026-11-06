import 'dart:io';

import 'package:ayma_flutter/services/async_voice_controller.dart';
import 'package:ayma_flutter/services/async_voice_queue.dart';
import 'package:ayma_flutter/services/async_voice_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRecorder implements AsyncVoiceRecorder {
  bool allowed = true;
  bool throwOnStart = false;
  int sizeBytes = 2048;
  bool returnNullOnStop = false;
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
}
