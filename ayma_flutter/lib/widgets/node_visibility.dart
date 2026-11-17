/// The coloured bullet that marks every node's visibility (founder Nov 17):
/// public = green, private = yellow, AI-only = a third distinct colour. A
/// parent whose subtree holds BOTH public and private shows a SPLIT bullet —
/// half yellow, half green, yin-yang style. The same colour language is used in
/// the person graph.
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';

/// Visibility → colour. `public` green, `private` yellow (amber), `ayma_only`
/// the AI-only colour (a distinct blue-violet).
Color nodeVisibilityColor(String visibility) {
  switch (visibility) {
    case NodeVis.public:
      return const Color(0xFF34C759); // green
    case NodeVis.private:
      return const Color(0xFFFFCC00); // yellow
    case NodeVis.aymaOnly:
      return const Color(0xFF7C5CFF); // AI-only (blue-violet)
    default:
      return const Color(0xFFFFCC00);
  }
}

/// A small circular bullet coloured by [visibility]. A `mixed` subtree paints
/// the split (half public-green, half private-yellow) yin-yang bullet.
class NodeVisibilityBullet extends StatelessWidget {
  const NodeVisibilityBullet({
    super.key,
    required this.visibility,
    this.size = 10,
  });

  final String visibility;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (visibility == NodeVis.mixed) {
      return SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _SplitBulletPainter(
            first: nodeVisibilityColor(NodeVis.private),
            second: nodeVisibilityColor(NodeVis.public),
          ),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: nodeVisibilityColor(visibility),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Paints a circle split down the diagonal into two colours (the yin-yang
/// mixed-subtree bullet).
class _SplitBulletPainter extends CustomPainter {
  _SplitBulletPainter({required this.first, required this.second});

  final Color first;
  final Color second;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.clipPath(Path()..addOval(rect));
    // left/top half
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close(),
      Paint()..color = first,
    );
    // right/bottom half
    canvas.drawPath(
      Path()
        ..moveTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()..color = second,
    );
  }

  @override
  bool shouldRepaint(covariant _SplitBulletPainter old) =>
      old.first != first || old.second != second;
}
