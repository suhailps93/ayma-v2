import 'package:flutter/material.dart';

import '../services/async_voice_controller.dart';
import '../services/async_voice_queue.dart';
import '../services/connection_heartbeat.dart';
import '../theme.dart';
import 'ayma_wing_loader.dart';

/// The offered fallback when a live call cannot connect (Chunk A): a
/// press-and-hold voice-message recorder in a bottom sheet.
///
/// Hold the button, speak, release — the clip queues on the phone and
/// uploads whenever the connection allows, and Ayma's spoken reply lands
/// in the same thread. The wing loader under the button names the real
/// stage (`AymaLoaderLines.asyncVoice`, driven by the job's status).
Future<void> showAsyncVoiceSheet(
  BuildContext context, {
  AsyncVoiceController? controller,
  AsyncVoiceQueue? queue,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.ac.bgElev,
    showDragHandle: true,
    builder: (sheetContext) =>
        AsyncVoiceSheet(controller: controller, queue: queue),
  );
}

class AsyncVoiceSheet extends StatefulWidget {
  const AsyncVoiceSheet({super.key, this.controller, this.queue});

  /// A controller owned by the caller (the chat screen shares its own so
  /// the sheet and the inline recording bar never double-record). Null
  /// builds a throwaway one for this sheet only.
  final AsyncVoiceController? controller;
  final AsyncVoiceQueue? queue;

  @override
  State<AsyncVoiceSheet> createState() => _AsyncVoiceSheetState();
}

class _AsyncVoiceSheetState extends State<AsyncVoiceSheet> {
  late final AsyncVoiceController _controller =
      widget.controller ?? AsyncVoiceController(queue: _queue);
  late final AsyncVoiceQueue _queue = widget.queue ?? AsyncVoiceQueue.instance;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_harvestError);
  }

  void _harvestError() {
    final e = _controller.takeError();
    if (e != null && mounted) setState(() => _error = e);
  }

  @override
  void dispose() {
    _controller.removeListener(_harvestError);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  String _clock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SafeArea(
      // Scrolls in a short window (landscape, split-screen) or at large
      // text instead of overflowing — the out-of-credits sheet's pattern.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        child: ListenableBuilder(
          listenable: Listenable.merge([
            _controller,
            _queue,
            ConnectionHeartbeat.instance.listenable,
          ]),
          builder: (context, _) {
            final state = _controller.state;
            final jobId = _controller.activeJobId;
            final recording = state == AsyncVoiceUiState.recording;
            final working = state == AsyncVoiceUiState.working && jobId != null;
            final offline =
                ConnectionHeartbeat.instance.state == ConnectionQuality.offline;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Voice message',
                  textAlign: TextAlign.center,
                  style: AymaType.serif(size: 20, color: ac.fg),
                ),
                const SizedBox(height: 6),
                Text(
                  'Hold the button, speak, release. It sends when the '
                  'connection allows — Ayma answers out loud in the thread.',
                  textAlign: TextAlign.center,
                  style: AymaType.sans(size: 13, color: ac.fgMute),
                ),
                const SizedBox(height: 20),
                Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPressStart: (_) {
                      setState(() => _error = null);
                      _controller.startRecording();
                    },
                    onLongPressEnd: (_) => _controller.stopAndSend(),
                    onLongPressCancel: () => _controller.cancelRecording(),
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: recording ? AymaColors.error : ac.accent,
                      ),
                      child: Icon(
                        recording ? Icons.mic_rounded : Icons.mic_none_rounded,
                        size: 34,
                        color: recording ? Colors.white : ac.onAccent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 96,
                  child: Center(
                    child: _status(ac, recording, working, offline, jobId),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: AymaType.sans(size: 13, color: AymaColors.error),
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    if (recording) _controller.cancelRecording();
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    recording ? 'Cancel recording' : 'Close',
                    style: AymaType.sans(size: 14, color: ac.fgDim),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _status(
    AymaTokens ac,
    bool recording,
    bool working,
    bool offline,
    String? jobId,
  ) {
    if (recording) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _clock(_controller.elapsed),
            style: AymaType.mono(size: 22, color: ac.fg),
          ),
          const SizedBox(height: 4),
          Text(
            'Release to send',
            style: AymaType.sans(size: 13, color: ac.fgMute),
          ),
        ],
      );
    }
    if (working) {
      if (offline) {
        return Text(
          "Queued — sends when you're back online",
          textAlign: TextAlign.center,
          style: AymaType.sans(size: 13, color: ac.fgMute),
        );
      }
      return AymaWingLoader(
        size: 40,
        lines: AymaLoaderLines.asyncVoice,
        stage: _queue.stageFor(jobId!),
      );
    }
    return Text(
      'Hold to record',
      style: AymaType.sans(size: 13, color: ac.fgMute),
    );
  }
}
