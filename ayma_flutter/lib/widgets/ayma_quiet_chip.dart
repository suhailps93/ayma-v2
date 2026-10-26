import 'package:flutter/material.dart';

import '../theme.dart';

/// Shown during a live voice call while the agent has been told to "shut up"
/// (server-side mute) so the silence reads as deliberate, not broken — with
/// an explicit Unmute button ([onUnmute], normally
/// `VoiceSessionController.unmuteAyma`). Saying "Ayma" still wakes her too.
/// Used on the call screen and in the chat composer (full chat page and the
/// partial chat sheet).
class AymaQuietChip extends StatelessWidget {
  const AymaQuietChip({super.key, required this.onUnmute});

  final VoidCallback onUnmute;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ac.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_off_rounded, size: 16, color: ac.accent),
          const SizedBox(width: 8),
          Flexible(
            child: Semantics(
              liveRegion: true,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Ayma is quiet',
                      style: AymaType.sans(
                        size: 12.5,
                        color: ac.fg,
                        weight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: ' · or say “Ayma”',
                      style: AymaType.sans(size: 12.5, color: ac.fgDim),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Unmute Ayma',
            excludeSemantics: true,
            onTap: onUnmute,
            child: TextButton.icon(
              key: const Key('aymaQuietUnmute'),
              onPressed: onUnmute,
              icon: const Icon(Icons.volume_up_rounded, size: 16),
              label: const Text('Unmute'),
              style: TextButton.styleFrom(
                foregroundColor: ac.onAccent,
                backgroundColor: ac.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: const StadiumBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
