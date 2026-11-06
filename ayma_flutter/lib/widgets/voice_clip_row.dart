import 'package:flutter/material.dart';

import '../services/async_voice_player.dart';
import '../theme.dart';

/// The play row on a voice-message transcript turn (Chunk A): a play/stop
/// toggle plus a "Voice message" caption, tinted for the bubble it sits in.
///
/// [clipKey] identifies this turn's clip in the shared [nowPlaying] — only
/// one clip plays app-wide at a time. [audioUrl] wins; [audioFile] (a local
/// path) plays while the clip is still uploading.
class VoiceClipRow extends StatelessWidget {
  const VoiceClipRow({
    super.key,
    this.audioUrl,
    this.audioFile,
    required this.player,
    required this.nowPlaying,
    required this.clipKey,
    required this.iconColor,
    required this.captionColor,
  });

  final String? audioUrl;
  final String? audioFile;
  final AsyncVoicePlayer player;
  final ValueNotifier<String?> nowPlaying;
  final String clipKey;
  final Color iconColor;
  final Color captionColor;

  bool get _hasClip =>
      (audioUrl != null && audioUrl!.isNotEmpty) ||
      (audioFile != null && audioFile!.isNotEmpty);

  Future<void> _toggle() async {
    if (nowPlaying.value == clipKey && player.playing.value) {
      nowPlaying.value = null;
      await player.stop();
      return;
    }
    nowPlaying.value = clipKey;
    try {
      if (audioUrl != null && audioUrl!.isNotEmpty) {
        await player.playUrl(audioUrl!);
      } else if (audioFile != null && audioFile!.isNotEmpty) {
        await player.playFile(audioFile!);
      }
    } catch (_) {
      // A clip that won't play (deleted URL, transient fetch) stops the
      // spinner honestly: nothing is playing, so say so.
      if (nowPlaying.value == clipKey) nowPlaying.value = null;
      debugPrint('VoiceClipRow playback failed for $clipKey');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasClip) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([player.playing, nowPlaying]),
      builder: (context, _) {
        final mine = nowPlaying.value == clipKey && player.playing.value;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                mine ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: 22,
                color: iconColor,
              ),
              const SizedBox(width: 4),
              Text(
                'Voice message',
                style: AymaType.sans(size: 12, color: captionColor),
              ),
            ],
          ),
        );
      },
    );
  }
}
