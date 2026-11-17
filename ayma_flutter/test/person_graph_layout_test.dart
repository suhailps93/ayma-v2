// Targeted tests for the live person-graph layout (Track C):
//  (a) fit-bounds math — a graph whose natural bounds exceed the viewport is
//      scaled/translated so every node lands inside the visible area with
//      padding.
//  (b) collision separation — on a synthetic dense cluster (many children under
//      one parent), no two nodes overlap once the simulation settles.
import 'dart:ui';

import 'package:ayma_flutter/screens/person_graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fitToViewport', () {
    test('a graph larger than the viewport fits inside with padding', () {
      // Nodes spread far wider/taller than the viewport.
      final nodes = <SimNode>[
        SimNode(id: 'a', level: 0)
          ..x = -2000
          ..y = -1500,
        SimNode(id: 'b', level: 1)
          ..x = 2200
          ..y = 1800,
        SimNode(id: 'c', level: 2)
          ..x = 500
          ..y = -900,
        SimNode(id: 'd', level: 3)
          ..x = -1300
          ..y = 1200,
      ];
      const viewport = Size(400, 720);
      const padding = 32.0;
      final bounds = graphBounds(nodes);
      final fit = fitToViewport(bounds, viewport, padding: padding);

      expect(fit.scale, greaterThan(0));
      expect(fit.scale, lessThanOrEqualTo(2.2));

      // Every node's DRAWN extent (centre ± radius, in viewport space) lands
      // inside the viewport, and no closer than `padding` to any edge.
      for (final n in nodes) {
        final c = fit.toViewport(n.pos);
        final r = n.radius * fit.scale;
        expect(c.dx - r, greaterThanOrEqualTo(padding - 0.5),
            reason: '${n.id} left edge');
        expect(c.dx + r, lessThanOrEqualTo(viewport.width - padding + 0.5),
            reason: '${n.id} right edge');
        expect(c.dy - r, greaterThanOrEqualTo(padding - 0.5),
            reason: '${n.id} top edge');
        expect(c.dy + r, lessThanOrEqualTo(viewport.height - padding + 0.5),
            reason: '${n.id} bottom edge');
      }
    });

    test('a tiny graph is centred, not blown up past maxScale', () {
      final nodes = <SimNode>[
        SimNode(id: 'a', level: 0),
        SimNode(id: 'b', level: 2)
          ..x = 10
          ..y = 8,
      ];
      const viewport = Size(400, 720);
      final fit = fitToViewport(graphBounds(nodes), viewport, maxScale: 2.2);
      expect(fit.scale, lessThanOrEqualTo(2.2));
      // Stays on-screen.
      for (final n in nodes) {
        final c = fit.toViewport(n.pos);
        expect(c.dx, inInclusiveRange(0, viewport.width));
        expect(c.dy, inInclusiveRange(0, viewport.height));
      }
    });
  });

  group('collision separation', () {
    test('a dense cluster settles with no two nodes overlapping', () {
      // One parent with 70 leaves — the founder's overlapping-blob case.
      final nodes = <SimNode>[SimNode(id: 'root', level: 0)];
      final edges = <(String, String)>[];
      for (var i = 0; i < 70; i++) {
        nodes.add(SimNode(id: 'c$i', level: 2));
        edges.add(('root', 'c$i'));
      }
      final sim = GraphSim(nodes: nodes, edges: edges, centerId: 'root');
      sim.settle();

      expect(sim.isSettled, isTrue);
      expect(sim.anyOverlap(), isFalse,
          reason: 'no two drawn node circles may overlap after settle');
    });

    test('a multi-section graph settles overlap-free and bounded', () {
      final nodes = <SimNode>[SimNode(id: 'me', level: 0)];
      final edges = <(String, String)>[];
      for (var s = 0; s < 6; s++) {
        final sec = 'sec$s';
        nodes.add(SimNode(id: sec, level: 1));
        edges.add(('me', sec));
        for (var i = 0; i < 20; i++) {
          final leaf = '$sec.$i';
          nodes.add(SimNode(id: leaf, level: 2));
          edges.add((sec, leaf));
        }
      }
      // 1 + 6 + 120 = 127 nodes.
      final sim = GraphSim(nodes: nodes, edges: edges, centerId: 'me');
      sim.settle();

      expect(sim.anyOverlap(), isFalse);
      // The layout is finite (no exploded NaN/Infinity positions).
      for (final n in sim.nodes) {
        expect(n.x.isFinite, isTrue);
        expect(n.y.isFinite, isTrue);
      }
    });
  });
}
