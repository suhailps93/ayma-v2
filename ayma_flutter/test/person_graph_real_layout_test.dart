// Regression on the FOUNDER'S REAL graph (uid iWhWjiWh…, read-only ayma-staging
// dump): 122 nodes / 121 edges, dominated by one sec:assessment hub with 96
// degree-1 children. Pre-fix the force sim EXPLODES this to ~1e6 coordinates
// (a node ~98× the median distance; bounds aspect ~4.6; fitToViewport clamps to
// scale 0.02) → the founder's "pink streak / comet tail, graph knotted
// off-screen" (build 2495). The per-step velocity clamp keeps the integration
// stable so the real graph settles into a fitted mesh. Fail-before / pass-after.
import 'dart:math' as math;
import 'dart:ui';

import 'package:ayma_flutter/screens/person_graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/founder_real_graph.dart';

/// BFS levels from 'me', mirroring the screen's `_computeLevels`.
Map<String, int> _levels(List<List<String>> edges, Set<String> ids) {
  final childrenOf = <String, Set<String>>{};
  final parentsOf = <String, Set<String>>{};
  for (final e in edges) {
    (childrenOf[e[0]] ??= {}).add(e[1]);
    (parentsOf[e[1]] ??= {}).add(e[0]);
  }
  final lvl = <String, int>{'me': 0};
  final q = <String>['me'];
  var h = 0;
  while (h < q.length) {
    final cur = q[h++];
    for (final nb in [...?childrenOf[cur], ...?parentsOf[cur]]) {
      if (!lvl.containsKey(nb)) {
        lvl[nb] = lvl[cur]! + 1;
        q.add(nb);
      }
    }
  }
  for (final id in ids) {
    lvl.putIfAbsent(id, () => 2);
  }
  return lvl;
}

GraphSim _buildRealSim() {
  final ids = {for (final n in founderRealNodes) n[0]};
  final lvl = _levels(founderRealEdges, ids);
  final nodes = [
    for (final n in founderRealNodes) SimNode(id: n[0], level: lvl[n[0]]!)
  ];
  final edges = [for (final e in founderRealEdges) (e[0], e[1])];
  return GraphSim(nodes: nodes, edges: edges, centerId: 'me');
}

void main() {
  test('the founder real graph settles stable (no explosion)', () {
    expect(founderRealNodes.length, greaterThan(100));
    final sim = _buildRealSim();
    sim.settle();
    expect(sim.isSettled, isTrue);
    expect(sim.anyOverlap(), isFalse);

    var cx = 0.0, cy = 0.0;
    for (final n in sim.nodes) {
      expect(n.x.isFinite && n.y.isFinite, isTrue, reason: '${n.id} finite');
      cx += n.x;
      cy += n.y;
    }
    cx /= sim.nodes.length;
    cy /= sim.nodes.length;
    final dists = sim.nodes
        .map((n) => math.sqrt((n.x - cx) * (n.x - cx) + (n.y - cy) * (n.y - cy)))
        .toList()
      ..sort();
    final median = dists[dists.length ~/ 2];
    // No runaway node: the farthest is within a small multiple of the median.
    // (Pre-fix the 96-child hub flew to ~98× the median.)
    expect(dists.last, lessThanOrEqualTo(5 * median),
        reason: 'no node may explode far from the cluster');

    // Bounds are not a thin horizontal streak (pre-fix aspect ~4.6 → comet tail).
    final b = graphBounds(sim.nodes);
    final aspect = b.width / b.height;
    expect(aspect, inInclusiveRange(0.4, 2.5),
        reason: 'the settled cluster is roughly square, not a streak');
  });

  test('the founder real graph fits the viewport on both axes', () {
    final sim = _buildRealSim();
    sim.settle();

    const viewport = Size(380, 600);
    const padding = 32.0;
    final fit = fitToViewport(graphBounds(sim.nodes), viewport, padding: padding);

    // Not crushed to the minScale floor (pre-fix 0.02 crushed everything).
    expect(fit.scale, greaterThan(0.1), reason: 'not clamped to minScale');

    double minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
    for (final n in sim.nodes) {
      final c = fit.toViewport(n.pos);
      final r = n.radius * fit.scale;
      // every drawn node on-screen
      expect(c.dx - r, greaterThanOrEqualTo(padding - 0.5), reason: '${n.id} L');
      expect(c.dx + r, lessThanOrEqualTo(viewport.width - padding + 0.5),
          reason: '${n.id} R');
      expect(c.dy - r, greaterThanOrEqualTo(padding - 0.5), reason: '${n.id} T');
      expect(c.dy + r, lessThanOrEqualTo(viewport.height - padding + 0.5),
          reason: '${n.id} B');
      minx = math.min(minx, c.dx);
      maxx = math.max(maxx, c.dx);
      miny = math.min(miny, c.dy);
      maxy = math.max(maxy, c.dy);
    }
    // Fills a reasonable share of BOTH axes (not a knot in a corner).
    final usableW = viewport.width - 2 * padding;
    final usableH = viewport.height - 2 * padding;
    expect(maxx - minx, greaterThanOrEqualTo(0.5 * usableW),
        reason: 'cluster fills the width');
    expect(maxy - miny, greaterThanOrEqualTo(0.3 * usableH),
        reason: 'cluster fills a reasonable height (no single-axis crush)');
  });
}
