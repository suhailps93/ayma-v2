import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Live force-directed layout for the person graph (founder direction, Nov 16
/// 2026): link springs + node repulsion that settle and then STOP, with a hard
/// collision pass so no two nodes overlap. Pure geometry (no Flutter widgets)
/// so the fit-bounds math and collision separation are unit-testable without a
/// widget harness. The screen drives [GraphSim.step] from a [Ticker] and paints
/// the node positions through [fitToViewport].

/// Rendered radius for a node at [level] (0 = the person, 1 = a section, 2 =
/// a first-generation leaf, deeper shrinks). Size encodes level — person
/// largest, sections next, bullets shrinking with depth — and the collision
/// radius is this plus a small gap so size and spacing stay consistent.
double nodeRadiusForLevel(int level) => switch (level) {
      <= 0 => 22,
      1 => 14,
      2 => 9.5,
      3 => 7.5,
      _ => 6,
    };

/// A node in the force simulation. Position/velocity are mutated in place each
/// [GraphSim.step]; [radius] is the rendered size (from [nodeRadiusForLevel]).
class SimNode {
  SimNode({required this.id, required this.level})
      : radius = nodeRadiusForLevel(level);

  final String id;
  final int level;
  final double radius;
  double x = 0;
  double y = 0;
  double vx = 0;
  double vy = 0;

  /// The circle used for overlap resolution — the drawn radius plus a gap so
  /// settled nodes keep clear air between them.
  double get collisionRadius => radius + 3.0;
  double get mass => radius * radius;
  Offset get pos => Offset(x, y);
}

/// Axis-aligned bounds of [nodes], expanded by each node's radius so the drawn
/// circle (not just its centre) is inside. An empty set returns a unit rect.
Rect graphBounds(Iterable<SimNode> nodes) {
  double? minX, minY, maxX, maxY;
  for (final n in nodes) {
    final r = n.radius;
    minX = math.min(minX ?? (n.x - r), n.x - r);
    minY = math.min(minY ?? (n.y - r), n.y - r);
    maxX = math.max(maxX ?? (n.x + r), n.x + r);
    maxY = math.max(maxY ?? (n.y + r), n.y + r);
  }
  if (minX == null) return const Rect.fromLTWH(0, 0, 1, 1);
  return Rect.fromLTRB(minX, minY!, maxX!, maxY!);
}

/// A scene -> viewport transform: `viewport = scene * scale + offset`.
class ViewTransform {
  ViewTransform(this.scale, this.offset);
  factory ViewTransform.identity() => ViewTransform(1, Offset.zero);

  double scale;
  Offset offset;

  Offset toScene(Offset viewport) => (viewport - offset) / scale;
  Offset toViewport(Offset scene) => scene * scale + offset;
}

/// The scene -> viewport transform that fits [bounds] inside [viewport] leaving
/// [padding] logical px on every side. A graph larger than the viewport scales
/// down to fit; a tiny graph is not blown up past [maxScale]. Because [bounds]
/// already includes each node's radius, every node's drawn circle lands inside
/// the viewport with at least [padding] of margin.
ViewTransform fitToViewport(
  Rect bounds,
  Size viewport, {
  double padding = 32,
  double maxScale = 2.2,
  double minScale = 0.02,
}) {
  final availW = math.max(1.0, viewport.width - 2 * padding);
  final availH = math.max(1.0, viewport.height - 2 * padding);
  final bw = bounds.width <= 0 ? 1.0 : bounds.width;
  final bh = bounds.height <= 0 ? 1.0 : bounds.height;
  var scale = math.min(availW / bw, availH / bh);
  if (scale.isNaN || !scale.isFinite) scale = 1.0;
  scale = scale.clamp(minScale, maxScale);
  final offX = (viewport.width - bw * scale) / 2 - bounds.left * scale;
  final offY = (viewport.height - bh * scale) / 2 - bounds.top * scale;
  return ViewTransform(scale, Offset(offX, offY));
}

/// A force-directed graph simulation. Forces (spring + repulsion + weak
/// centring) cool with [alpha]; a hard collision pass runs at full strength
/// every step so the settled frame is overlap-free. Once [isSettled] the
/// screen stops its ticker — no perpetual physics.
class GraphSim {
  GraphSim({
    required List<SimNode> nodes,
    required List<(String, String)> edges,
    this.centerId,
    int seed = 7,
  }) : nodes = nodes {
    _index = {for (var i = 0; i < nodes.length; i++) nodes[i].id: i};
    for (final (a, b) in edges) {
      final ia = _index[a];
      final ib = _index[b];
      if (ia != null && ib != null && ia != ib) _edges.add((ia, ib));
    }
    _seed(seed);
  }

  final List<SimNode> nodes;
  final String? centerId;
  late final Map<String, int> _index;
  final List<(int, int)> _edges = [];

  double alpha = 1.0;
  static const double alphaMin = 0.02;
  static const double _alphaDecay = 0.035;
  static const double _velocityDecay = 0.80;
  static const double _springK = 0.085;
  static const double _repel = 42.0;
  static const double _gravity = 0.015;
  static const int _collisionIters = 2;

  bool get isSettled => alpha <= alphaMin;

  /// Deterministic initial placement — the centre node at the origin, the rest
  /// on a golden-angle spiral with a little seeded jitter so the first frame is
  /// reproducible (tests) and the settle is stable.
  void _seed(int seed) {
    final rnd = math.Random(seed);
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (n.id == centerId) {
        n.x = 0;
        n.y = 0;
        continue;
      }
      final ang = i * 2.399963; // golden angle
      final rad = 28 + 13 * math.sqrt(i + 1) + rnd.nextDouble() * 8;
      n.x = math.cos(ang) * rad;
      n.y = math.sin(ang) * rad;
    }
  }

  double _restLen(SimNode a, SimNode b) {
    final gap = (a.level == 0 || b.level == 0) ? 40.0 : 26.0;
    return a.radius + b.radius + gap;
  }

  /// Advance the simulation one tick. O(n^2) in the node count, which is sane
  /// at the ~200-node founder scale; the collision pass runs at full strength
  /// so no two nodes overlap once the forces cool.
  void step() {
    if (alpha > alphaMin) {
      // Cool toward zero so alpha actually crosses alphaMin and the sim stops.
      alpha -= alpha * _alphaDecay;
    }
    final a = alpha;
    final n = nodes.length;

    // Spring force along every edge, pulling endpoints to their rest length.
    for (final (i, j) in _edges) {
      final ni = nodes[i];
      final nj = nodes[j];
      var dx = nj.x - ni.x;
      var dy = nj.y - ni.y;
      var dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1e-4) {
        dx = 0.01;
        dy = 0.0;
        dist = 0.01;
      }
      final rest = _restLen(ni, nj);
      final f = _springK * (dist - rest) * a / dist;
      final fx = dx * f;
      final fy = dy * f;
      ni.vx += fx;
      ni.vy += fy;
      nj.vx -= fx;
      nj.vy -= fy;
    }

    // Pairwise repulsion (inverse-square, capped) so clusters spread out.
    for (var i = 0; i < n; i++) {
      final ni = nodes[i];
      for (var j = i + 1; j < n; j++) {
        final nj = nodes[j];
        var dx = ni.x - nj.x;
        var dy = ni.y - nj.y;
        var d2 = dx * dx + dy * dy;
        if (d2 < 1e-4) {
          dx = (i - j).isEven ? 0.1 : -0.1;
          dy = 0.1;
          d2 = 0.02;
        }
        final dist = math.sqrt(d2);
        // Softened denominator keeps near pairs from exploding.
        final soft = dist + ni.radius + nj.radius;
        var f = _repel * (ni.radius + nj.radius) * a / (soft * soft);
        if (f > 4.0) f = 4.0;
        final fx = dx / dist * f;
        final fy = dy / dist * f;
        ni.vx += fx;
        ni.vy += fy;
        nj.vx -= fx;
        nj.vy -= fy;
      }
    }

    // Weak centring so disconnected components don't drift off to infinity.
    for (final node in nodes) {
      if (node.id == centerId) continue;
      node.vx -= node.x * _gravity * a;
      node.vy -= node.y * _gravity * a;
    }

    // Integrate with friction; pin the centre node at the origin.
    for (final node in nodes) {
      if (node.id == centerId) {
        node.vx = 0;
        node.vy = 0;
        node.x = 0;
        node.y = 0;
        continue;
      }
      node.vx *= _velocityDecay;
      node.vy *= _velocityDecay;
      node.x += node.vx;
      node.y += node.vy;
    }

    _resolveCollisions();
  }

  /// Hard, position-based overlap resolution — not scaled by [alpha], so the
  /// final settled frame has no two nodes overlapping however the forces land.
  void _resolveCollisions() {
    final n = nodes.length;
    for (var pass = 0; pass < _collisionIters; pass++) {
      for (var i = 0; i < n; i++) {
        final ni = nodes[i];
        for (var j = i + 1; j < n; j++) {
          final nj = nodes[j];
          final min = ni.collisionRadius + nj.collisionRadius;
          var dx = nj.x - ni.x;
          var dy = nj.y - ni.y;
          var d2 = dx * dx + dy * dy;
          if (d2 >= min * min) continue;
          var dist = math.sqrt(d2);
          if (dist < 1e-4) {
            // Coincident — nudge apart along a deterministic axis.
            dx = (i + j).isEven ? 1.0 : -1.0;
            dy = (i - j).isEven ? 1.0 : -1.0;
            dist = math.sqrt(dx * dx + dy * dy);
          }
          final overlap = (min - dist) / 2;
          final ux = dx / dist;
          final uy = dy / dist;
          final pinI = ni.id == centerId;
          final pinJ = nj.id == centerId;
          if (pinI && pinJ) continue;
          if (pinI) {
            nj.x += ux * overlap * 2;
            nj.y += uy * overlap * 2;
          } else if (pinJ) {
            ni.x -= ux * overlap * 2;
            ni.y -= uy * overlap * 2;
          } else {
            ni.x -= ux * overlap;
            ni.y -= uy * overlap;
            nj.x += ux * overlap;
            nj.y += uy * overlap;
          }
        }
      }
    }
  }

  /// Step until settled or [maxSteps] reached — used by reduced-motion mode and
  /// by tests that need the final frame.
  void settle({int maxSteps = 600}) {
    var steps = 0;
    while (!isSettled && steps < maxSteps) {
      step();
      steps++;
    }
    // A few final collision passes guarantee separation at rest.
    for (var i = 0; i < 4; i++) {
      _resolveCollisions();
    }
  }

  /// True when any two nodes' drawn circles overlap (ignores the collision gap)
  /// — a test helper for the collision-separation guarantee.
  bool anyOverlap({double tol = 0.01}) {
    final n = nodes.length;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final ni = nodes[i];
        final nj = nodes[j];
        final dx = ni.x - nj.x;
        final dy = ni.y - nj.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < ni.radius + nj.radius - tol) return true;
      }
    }
    return false;
  }
}
