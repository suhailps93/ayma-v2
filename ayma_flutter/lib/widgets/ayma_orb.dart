import 'package:flutter/material.dart';

import '../theme.dart';

/// The glowing gradient "orb" brand motif (§14.1). Used as Ayma's tab icon and
/// anywhere a voice/connection state needs a visual: [active] lights it with an
/// Ember glow, otherwise it sits dim.
class AymaOrb extends StatelessWidget {
  const AymaOrb({super.key, this.size = 26, this.active = false});

  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final core = active ? ac.accent : ac.fgMute;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            core,
            Color.lerp(core, ac.bg, 0.45)!,
          ],
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: ac.accent.withValues(alpha: 0.55),
                  blurRadius: size * 0.7,
                  spreadRadius: size * 0.1,
                ),
              ]
            : const [],
      ),
    );
  }
}
