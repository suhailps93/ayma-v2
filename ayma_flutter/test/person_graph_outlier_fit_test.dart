// Regression for the person-graph layout outlier + fit crush (founder build
// 2491: "pink streak to one distant point, cluster crushed into a corner").
//
// Root cause: an EDGELESS node (a cross-surface fact that never linked to a
// section) has no spring pulling it toward the graph. Under only weak gravity
// against full cluster repulsion it drifts out to a far equilibrium ring
// (~680px at founder scale). That lone far node dominates `graphBounds`, so
// `fitToViewport` zooms far out and the dense, readable cluster is squeezed
// into a corner. The fix anchors every edgeless node to the centre with a
// bounded virtual spring so it settles INSIDE the cluster, and `fitToViewport`
// then frames the true cluster.
//
// These assertions FAIL on the pre-fix sim (orphans on the far ring) and PASS
// after it (orphans inside the cluster; the fitted frame is not crushed).
import 'dart:math' as math;
import 'dart:ui';

import 'package:ayma_flutter/screens/person_graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deterministic founder-shaped graph: a centre "You" + weighted sections,
/// each with facts spread across the four surfaces (story / publicProfile /
/// report / graphDetail) and an occasional depth-3 sub-fact, PLUS a handful of
/// sparsely-connected (edgeless) cross-surface facts AND the lone Ayma-assessment
/// hub whose single child is the assessment root (a DEGREE-1 node with one long
/// edge — the grounding meta-node the founder keeps hitting with Skills on). This
/// mirrors the backend (`profile_graph._augment_with_store_nodes`): each store
/// node hangs under its own `sec:<page_type>` hub, which links to "me".
(List<SimNode>, List<(String, String)>, List<String>) founderShapedGraph() {
  final nodes = <SimNode>[SimNode(id: 'me', level: 0)];
  final edges = <(String, String)>[];
  final orphanIds = <String>[];
  final rnd = math.Random(17);
  const surfaces = ['story', 'publicProfile', 'report', 'graphDetail'];
  for (var s = 0; s < 12; s++) {
    final sec = 'sec$s';
    nodes.add(SimNode(id: sec, level: 1));
    edges.add(('me', sec));
    final fan = 6 + rnd.nextInt(9); // 6–14 facts
    for (var i = 0; i < fan; i++) {
      final leaf = '$sec.${surfaces[i % surfaces.length]}.$i';
      nodes.add(SimNode(id: leaf, level: 2));
      edges.add((sec, leaf));
      if (i % 8 == 3) {
        nodes.add(SimNode(id: '$leaf.sub', level: 3));
        edges.add((leaf, '$leaf.sub'));
      }
    }
  }
  // Edgeless cross-surface facts that never linked to a section.
  for (var k = 0; k < 5; k++) {
    final id = 'orphan$k';
    nodes.add(SimNode(id: id, level: 2));
    orphanIds.add(id);
  }
  // Lone Ayma-assessment hub + its single assessment child (degree-1).
  nodes.add(SimNode(id: 'sec:assess', level: 1));
  edges.add(('me', 'sec:assess'));
  nodes.add(SimNode(id: 'assessment', level: 2));
  edges.add(('sec:assess', 'assessment'));
  return (nodes, edges, orphanIds);
}

Offset _centroid(GraphSim sim) {
  var cx = 0.0, cy = 0.0;
  for (final n in sim.nodes) {
    cx += n.x;
    cy += n.y;
  }
  return Offset(cx / sim.nodes.length, cy / sim.nodes.length);
}

void main() {
  group('person graph: no outlier, fit frames the real cluster', () {
    test('every node (orphans included) settles in a bounded cluster', () {
      final (nodes, edges, orphanIds) = founderShapedGraph();
      expect(nodes.length, greaterThan(150));
      final sim = GraphSim(nodes: nodes, edges: edges, centerId: 'me');
      sim.settle();
      expect(sim.isSettled, isTrue);

      final c = _centroid(sim);
      final dists = <String, double>{};
      for (final n in sim.nodes) {
        final d = (n.pos - c).distance;
        expect(d.isFinite, isTrue, reason: '${n.id} finite distance');
        expect(n.x.isFinite && n.y.isFinite, isTrue, reason: '${n.id} finite pos');
        dists[n.id] = d;
      }
      final sorted = dists.values.toList()..sort();
      final median = sorted[sorted.length ~/ 2];

      // (a) No node is flung far from the cluster: the farthest node is within a
      //     small multiple of the median distance. (Pre-fix: an orphan on the
      //     ~680px ring over a ~250px-median cluster pushes this past 2.5x.)
      final maxD = sorted.last;
      expect(maxD, lessThanOrEqualTo(2.2 * median),
          reason: 'max distance $maxD must stay within 2.2x median $median');

      // (b) Every edgeless orphan settles INSIDE the cluster — not on the far
      //     repulsion ring. Pre-fix each orphan sat well beyond the median;
      //     post-fix each is within ~1.2x the median like a real leaf.
      for (final id in orphanIds) {
        expect(dists[id]!, lessThanOrEqualTo(1.2 * median),
            reason: 'orphan $id ($dists[$id]) must settle inside the cluster');
      }
    });

    test('fitToViewport frames the whole cluster without crushing it', () {
      final (nodes, edges, _) = founderShapedGraph();
      final sim = GraphSim(nodes: nodes, edges: edges, centerId: 'me');
      sim.settle();

      const viewport = Size(380, 600);
      const padding = 32.0;
      final fit = fitToViewport(graphBounds(sim.nodes), viewport, padding: padding);

      // Every drawn node circle lands inside the viewport.
      for (final n in sim.nodes) {
        final p = fit.toViewport(n.pos);
        final r = n.radius * fit.scale;
        expect(p.dx - r, greaterThanOrEqualTo(padding - 0.5), reason: '${n.id} L');
        expect(p.dx + r, lessThanOrEqualTo(viewport.width - padding + 0.5),
            reason: '${n.id} R');
        expect(p.dy - r, greaterThanOrEqualTo(padding - 0.5), reason: '${n.id} T');
        expect(p.dy + r, lessThanOrEqualTo(viewport.height - padding + 0.5),
            reason: '${n.id} B');
      }

      // The cluster is not crushed into a corner: the span of ALL node centres
      // in viewport space fills a reasonable fraction of the frame. Pre-fix the
      // far orphan ring shrank the dense cluster to a tiny corner blob; the real
      // graph must fill the width and sit well off the edges.
      double minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
      for (final n in sim.nodes) {
        final p = fit.toViewport(n.pos);
        minx = math.min(minx, p.dx);
        maxx = math.max(maxx, p.dx);
        miny = math.min(miny, p.dy);
        maxy = math.max(maxy, p.dy);
      }
      final usableW = viewport.width - 2 * padding;
      final usableH = viewport.height - 2 * padding;
      expect((maxx - minx), greaterThanOrEqualTo(0.6 * usableW),
          reason: 'cluster must fill the viewport width, not crush to a corner');
      // Centred, not pinned to a corner: the cluster's mid lands near centre.
      final midx = (minx + maxx) / 2;
      final midy = (miny + maxy) / 2;
      expect((midx - viewport.width / 2).abs(), lessThan(0.25 * viewport.width));
      expect((midy - viewport.height / 2).abs(), lessThan(0.25 * viewport.height));
      expect(usableH, greaterThan(0));
    });

    // Founder build 2491 (18:20 screenshot): with the Skills filter ON the lone
    // far node was the AYMA ASSESSMENT root — a DEGREE-1 node with one long edge.
    // It must settle inside the cluster like a leaf, and a Skills-filtered fit
    // (only the assessment hub + assessment visible) must frame it on-screen.
    test('the degree-1 assessment root settles inside and frames when filtered',
        () {
      final (nodes, edges, _) = founderShapedGraph();
      final sim = GraphSim(nodes: nodes, edges: edges, centerId: 'me');
      sim.settle();

      final c = _centroid(sim);
      final dists = {for (final n in sim.nodes) n.id: (n.pos - c).distance};
      final sorted = dists.values.toList()..sort();
      final median = sorted[sorted.length ~/ 2];
      // Inside the cluster, within the same bound as an edgeless orphan — NOT on
      // the far rim (pre-fix the lone grounding root dominated the fit bounds).
      expect(dists['assessment']!, lessThanOrEqualTo(1.2 * median),
          reason: 'assessment must settle inside the cluster like a leaf');

      // Skills-filtered view: only the assessment hub + its child are visible.
      final visible = sim.nodes
          .where((s) => s.id == 'sec:assess' || s.id == 'assessment')
          .toList();
      const viewport = Size(380, 600);
      const padding = 32.0;
      final fit =
          fitToViewport(graphBounds(visible), viewport, padding: padding);
      for (final s in visible) {
        final p = fit.toViewport(s.pos);
        final r = s.radius * fit.scale;
        expect(p.dx - r, greaterThanOrEqualTo(padding - 0.5),
            reason: '${s.id} L on-screen');
        expect(p.dx + r, lessThanOrEqualTo(viewport.width - padding + 0.5),
            reason: '${s.id} R on-screen');
        expect(p.dy - r, greaterThanOrEqualTo(padding - 0.5),
            reason: '${s.id} T on-screen');
        expect(p.dy + r, lessThanOrEqualTo(viewport.height - padding + 0.5),
            reason: '${s.id} B on-screen');
      }
    });

    // Soft global containment guarantee: no node of ANY degree can settle beyond
    // the cluster bound and dominate the fit. A weakly-connected component whose
    // internal spring is satisfied FAR from the graph (so neither the spring nor
    // weak gravity reels it within the settle) escapes to a huge coordinate
    // without containment — fail-before: ratio ~14 (max ~4000 over median ~290);
    // pass-after: the gentle self-scaling bound reels it to the cluster edge.
    test('a far-flung weakly-connected component is contained after settle', () {
      final (nodes, edges, _) = founderShapedGraph();
      // A degree-1 pair tied to each other but NOT to the centre, flung far.
      final p1 = SimNode(id: 'drift1', level: 2);
      final p2 = SimNode(id: 'drift2', level: 2);
      nodes.addAll([p1, p2]);
      edges.add(('drift1', 'drift2'));
      final sim = GraphSim(nodes: nodes, edges: edges, centerId: 'me');
      // Override the seed and fling the pair out together.
      p1
        ..x = 6000
        ..y = -4500
        ..vx = 0
        ..vy = 0;
      p2
        ..x = 6050
        ..y = -4500
        ..vx = 0
        ..vy = 0;
      sim.settle();

      final c = _centroid(sim);
      final dists = sim.nodes.map((n) => (n.pos - c).distance).toList()..sort();
      final median = dists[dists.length ~/ 2];
      for (final n in sim.nodes) {
        expect(n.x.isFinite && n.y.isFinite, isTrue, reason: '${n.id} finite');
      }
      expect(dists.last, lessThanOrEqualTo(2.5 * median),
          reason: 'no node may settle beyond the cluster bound after a fling');
    });
  });
}
