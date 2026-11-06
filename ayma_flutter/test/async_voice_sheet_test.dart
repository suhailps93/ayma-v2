import 'dart:io';

import 'package:ayma_flutter/services/async_voice_controller.dart';
import 'package:ayma_flutter/services/async_voice_queue.dart';
import 'package:ayma_flutter/services/async_voice_recorder.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/async_voice_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    // Answered from memory — no file IO, so the hold runs under the widget
    // test's fake clock (real IO never resolves there).
    return RecordedClip(path: path, sizeBytes: 2048);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> discard(String path) async {}

  @override
  void dispose() {}
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
}

Future<void> _openSheet(
  WidgetTester tester, {
  required AsyncVoiceController controller,
  required AsyncVoiceQueue queue,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showAsyncVoiceSheet(
              tester.element(find.byType(ElevatedButton)),
              controller: controller,
              queue: queue,
            ),
            child: const Text('trigger'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('trigger'));
  await tester.pumpAndSettle();
}

/// A real press-and-hold on the sheet's hold button, kept down past the
/// long-press timeout so the mid-record UI can be asserted before release.
Future<TestGesture> _hold(WidgetTester tester) async {
  final hold = find.byIcon(Icons.mic_none_rounded);
  expect(hold, findsOneWidget);
  final gesture = await tester.startGesture(tester.getCenter(hold));
  await tester.pump(const Duration(milliseconds: 600));
  return gesture;
}

void main() {
  testWidgets('sheet explains hold-speak-release', (tester) async {
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(
      recorder: _FakeRecorder(),
      queue: queue,
    );
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);

    await _openSheet(tester, controller: controller, queue: queue);
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('Hold to record'), findsOneWidget);
    expect(find.textContaining('Hold the button'), findsOneWidget);
  });

  testWidgets('hold records, release sends and shows the live stage', (
    tester,
  ) async {
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(
      recorder: _FakeRecorder(),
      queue: queue,
    );
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);

    await _openSheet(tester, controller: controller, queue: queue);
    final gesture = await _hold(tester);
    expect(controller.state, AsyncVoiceUiState.recording);
    expect(find.text('Release to send'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d\d:\d\d')), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(queue.delivered, hasLength(1));
    expect(find.text('Sending your voice…'), findsOneWidget);
  });

  testWidgets('a denied mic shows the honest error in the sheet', (
    tester,
  ) async {
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(
      recorder: _FakeRecorder()..allowed = false,
      queue: queue,
    );
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);

    await _openSheet(tester, controller: controller, queue: queue);
    final gesture = await _hold(tester);
    await gesture.up();
    await tester.pump();
    expect(find.textContaining('Microphone'), findsOneWidget);
    expect(queue.delivered, isEmpty);
  });

  testWidgets('closing mid-record cancels the recording', (tester) async {
    final queue = _FakeQueue();
    final controller = AsyncVoiceController(
      recorder: _FakeRecorder(),
      queue: queue,
    );
    addTearDown(controller.dispose);
    addTearDown(queue.dispose);

    await _openSheet(tester, controller: controller, queue: queue);
    final gesture = await _hold(tester);
    expect(controller.state, AsyncVoiceUiState.recording);

    // Dismiss via the sheet's own Cancel with the finger still down.
    await tester.tap(find.text('Cancel recording'));
    await tester.pumpAndSettle();
    await gesture.up();
    expect(controller.state, AsyncVoiceUiState.idle);
    expect(queue.delivered, isEmpty);
  });
}
