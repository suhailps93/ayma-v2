import 'package:flutter/material.dart';

import '../theme.dart';

/// Shown during a live voice call while the agent has been told to "shut up"
/// (server-side mute) so the silence reads as deliberate, not broken.
class AymaQuietChip extends StatelessWidget {
  const AymaQuietChip({super.key});

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_off_rounded, size: 16, color: ac.accent),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Ayma is quiet — say “Ayma” to wake her',
                style: AymaType.sans(size: 12.5, color: ac.fgDim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
