import 'package:flutter/material.dart';

import '../services/async_voice_player.dart';
import '../theme.dart';

/// The play row on a voice-message transcript turn (Chunk A): a large
/// WhatsApp-style circular play/pause button plus a "Voice message" caption,
/// tinted for the bubble it sits in.
///
/// The button is a 44dp filled circle (founder, 2026-11-06: the original
/// bare 22dp triangle was too small to hit at a glance). It shows pause
/// while this clip is playing and toggles playback off when tapped again.
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

  /// Diameter of the circular play/pause button — a full-size hit target
  /// in the WhatsApp voice-memo range (40–48dp).
  static const double buttonSize = 44;

  @override
  Widget build(BuildContext context) {
    if (!_hasClip) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([player.playing, nowPlaying]),
      builder: (context, _) {
        final mine = nowPlaying.value == clipKey && player.playing.value;
        // The glyph contrasts with the filled circle the way WhatsApp's
        // white triangle contrasts with its green button: dark ink on a
        // light fill, white on a dark/saturated fill.
        final glyphColor = iconColor.computeLuminance() > 0.4
            ? AymaColors.lightFg
            : Colors.white;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: mine ? 'Pause voice message' : 'Play voice message',
                child: Container(
                  key: const ValueKey('voiceClipPlayButton'),
                  width: buttonSize,
                  height: buttonSize,
                  decoration: BoxDecoration(
                    color: iconColor,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    mine ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 26,
                    color: glyphColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
