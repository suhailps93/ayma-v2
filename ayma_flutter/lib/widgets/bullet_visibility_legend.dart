/// A small, plain-words key for the coloured visibility bullets that mark every
/// node in Your Story and the person graph (founder, build 2488: "too many
/// bullet colours and I don't know what each means"). It draws its dots through
/// the very same [NodeVisibilityBullet] the bullets themselves use — the exact
/// green/yellow/violet and the half-yellow/half-green "Mixed" split — so the key
/// can never drift from what it explains. One row that wraps to a second line at
/// tiny widths, large text scales or in RTL rather than overflowing. NOT shown
/// on the public profile, where every bullet is public and there is nothing to
/// explain.
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../theme.dart';
import 'node_visibility.dart';

/// One compact row of four `dot + label` pairs keying the bullet visibility
/// colours. Reusable: rendered once at the top of Your Story and once at the
/// top of the person graph.
class BulletVisibilityLegend extends StatelessWidget {
  const BulletVisibilityLegend({super.key});

  /// (visibility token, plain label) — the exact tokens [NodeVisibilityBullet]
  /// colours by, so the dot colours are the bullet colours by construction.
  static const _entries = <(String, String)>[
    (NodeVis.public, 'Public'),
    (NodeVis.private, 'Private'),
    (NodeVis.aymaOnly, 'Ayma only'),
    (NodeVis.mixed, 'Mixed'),
  ];

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final (vis, label) in _entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NodeVisibilityBullet(visibility: vis, size: 9),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: AymaType.sans(size: 11, color: ac.fgMute),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
