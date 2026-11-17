import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/bullet_visibility.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/photo_gallery.dart';

/// "My person graph" — a neural-network-style map of EVERYTHING the graph store
/// holds about the person (founder direction, Nov 16 2026). The person is the
/// central neuron; each section is a hub neuron; every leaf node — story
/// bullets, the Appearance and web-findings reports, photos, skills and Ayma's
/// assessment — is a smaller neuron clustered around its hub, wired by glowing
/// synapses. Pinch to zoom and pan the whole web. Tapping a node opens its
/// report or photo, or shows its detail; tapping a hub focuses its cluster.
/// [uid] shows another member's graph (public nodes only); null is the
/// signed-in user's own.
/// The route a tappable REPORT node pushes when opened, or null when the node
/// isn't a pushable report (images open a [PhotoViewer] dialog instead; every
/// other node just shows its detail). Pure so the routing is unit-testable.
String? graphOpenRoute(GraphNode n) => switch (n.openType) {
      'appearance_report' =>
        '/appearance/${n.openId.isEmpty ? 'current' : n.openId}',
      'webfind_report' => n.openId.isEmpty ? null : '/deep-dive/${n.openId}',
      _ => null,
    };

class PersonGraphScreen extends StatefulWidget {
  const PersonGraphScreen({super.key, this.api, this.uid});

  static const path = '/profile/graph';

  final ApiClient? api;
  final String? uid;

  @override
  State<PersonGraphScreen> createState() => _PersonGraphScreenState();
}

class _PersonGraphScreenState extends State<PersonGraphScreen>
    with ScreenContextReasserter<PersonGraphScreen>, SingleTickerProviderStateMixin {
  late final ApiClient _api = widget.api ?? ApiClient();
  PersonGraph? _graph;
  String? _error;
  String? _selected; // the selected/focused node id
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
    reassertScreenContext();
    unawaited(_load());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  void reassertScreenContext() => AppContext.instance.set(screen: 'person_graph');

  Future<void> _load() async {
    setState(() {
      _error = null;
      _graph = null;
    });
    try {
      final g = await _api.profileGraph(uid: widget.uid);
      if (mounted) setState(() => _graph = g);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't load the graph.");
    }
  }

  void _onTapNode(GraphNode n) {
    // A photo node opens the viewer; a report node pushes its report route;
    // everything else focuses and shows its detail.
    if (n.openType == 'image') {
      if (n.imageUrl.isNotEmpty) {
        showDialog<void>(
          context: context,
          builder: (_) => PhotoViewer(url: n.imageUrl, caption: n.text),
        );
      }
      return;
    }
    final route = graphOpenRoute(n);
    if (route != null) {
      context.push(route);
      return;
    }
    setState(() => _selected = _selected == n.id ? null : n.id);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final g = _graph;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: Text(widget.uid == null ? 'My person graph' : 'Person graph'),
        actions: [
          if (g != null)
            IconButton(
              tooltip: 'What the colours mean',
              icon: const Icon(Icons.info_outline),
              onPressed: () => _showLegend(context),
            ),
        ],
      ),
      body: _error != null
          ? CenteredScroll(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: AymaType.sans(size: 14, color: ac.errorText)),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _load,
                    style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : g == null
              ? const Center(child: CircularProgressIndicator())
              : _GraphBody(
                  graph: g,
                  selected: _selected,
                  pulse: _pulse,
                  onTapNode: _onTapNode,
                ),
    );
  }

  void _showLegend(BuildContext context) {
    final ac = context.ac;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ac.bgCard,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('In this graph',
                  style: AymaType.serif(size: 18, color: ac.fg)),
              const SizedBox(height: 4),
              Text(
                'Everything Ayma holds about you, wired together. Pinch to zoom, '
                'drag to pan. Tap a report or photo to open it.',
                style: AymaType.sans(size: 13, color: ac.fgDim),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 10,
                children: [
                  for (final (label, color) in _legendKinds(ac))
                    _LegendDot(label: label, color: color),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<(String, Color)> _legendKinds(AymaTokens ac) => [
      ('You', ac.accent),
      ('Section', _GraphColors.section(ac)),
      ('Fact', bulletVisibilityColor(ac, 'public')),
      ('Report', _GraphColors.report),
      ('Photo', _GraphColors.image),
      ('Skill', _GraphColors.skill),
      ("Ayma's read", _GraphColors.assess),
      ('Taste', _GraphColors.taste),
    ];

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: AymaType.sans(size: 12, color: ac.fgDim)),
      ],
    );
  }
}

/// Fixed accent colours for the node kinds — tuned to read on the dark neural
/// canvas in both app themes.
class _GraphColors {
  static const report = Color(0xFFE0A33E); // amber
  static const image = Color(0xFF4FC3D6); // cyan
  static const skill = Color(0xFF9B7BE0); // violet
  static const assess = Color(0xFFE07BB8); // magenta
  static const taste = Color(0xFF6FBF73); // green
  static const steering = Color(0xFFE08A5B); // orange
  static const interaction = Color(0xFF5B8AE0); // blue
  static Color section(AymaTokens ac) => ac.accent;

  static Color forNode(AymaTokens ac, GraphNode n) => switch (n.kind) {
        'person' => ac.accent,
        'section' => section(ac),
        'report' => report,
        'image' => image,
        'skill' => skill,
        'assess' => assess,
        'taste' => taste,
        'steering' => steering,
        'interaction' => interaction,
        _ => bulletVisibilityColor(ac, n.visibility),
      };
}

class _GraphBody extends StatefulWidget {
  const _GraphBody({
    required this.graph,
    required this.selected,
    required this.pulse,
    required this.onTapNode,
  });

  final PersonGraph graph;
  final String? selected;
  final Animation<double> pulse;
  final void Function(GraphNode node) onTapNode;

  @override
  State<_GraphBody> createState() => _GraphBodyState();
}

class _GraphBodyState extends State<_GraphBody> {
  final TransformationController _tc = TransformationController();

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final sel = widget.selected == null
        ? null
        : widget.graph.nodes.where((n) => n.id == widget.selected).firstOrNull;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final size = Size(c.maxWidth, c.maxHeight);
              final layout = _NeuralLayout(widget.graph, size);
              return ClipRect(
                child: InteractiveViewer(
                  transformationController: _tc,
                  minScale: 0.5,
                  maxScale: 6,
                  boundaryMargin: const EdgeInsets.all(120),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) {
                      final hit = layout.hit(d.localPosition);
                      if (hit != null) widget.onTapNode(hit);
                    },
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: widget.pulse,
                          builder: (context, _) => CustomPaint(
                            size: size,
                            painter: _NeuralPainter(
                              layout: layout,
                              ac: ac,
                              selected: widget.selected,
                              pulse: reduceMotion ? 0.5 : widget.pulse.value,
                              animate: !reduceMotion,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (sel != null && !sel.isOpenable) _DetailPanel(node: sel),
      ],
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.node});
  final GraphNode node;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isFact = node.kind == 'bullet' || node.kind == 'image';
    final color = isFact
        ? bulletVisibilityColor(ac, node.visibility)
        : _GraphColors.forNode(ac, node);
    final body = node.text.isNotEmpty ? node.text : node.label;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: ac.bgCard,
        border: Border(top: BorderSide(color: ac.lineSoft)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.label.isEmpty ? node.kind : node.label,
                    style: AymaType.sans(size: 13, color: ac.fgDim),
                  ),
                ),
                if (node.visibility.isNotEmpty) ...[
                  Icon(bulletVisibilityIcon(node.visibility), size: 13, color: color),
                  const SizedBox(width: 4),
                  Text(bulletVisibilityLabel(node.visibility),
                      style: AymaType.sans(size: 12, color: color)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: AymaType.sans(size: 15, color: ac.fg)),
          ],
        ),
      ),
    );
  }
}

/// Positions every node in the pixel space of [size]: the person at the
/// centre, sections on a ring, and each section's leaves spiralled around their
/// hub (a phyllotaxis spiral so dense clusters never overlap). The whole thing
/// is scaled to fit [size]; InteractiveViewer zooms in for detail.
class _NeuralLayout {
  _NeuralLayout(this.graph, this.size) {
    final byId = {for (final n in graph.nodes) n.id: n};
    final person = graph.nodes.where((n) => n.kind == 'person').firstOrNull;
    final sections = graph.nodes.where((n) => n.kind == 'section').toList();

    // hub -> its leaf node ids (from the hub->leaf edges).
    final children = <String, List<String>>{};
    for (final (from, to) in graph.edges) {
      if (byId[from]?.kind == 'section' &&
          byId[to] != null &&
          byId[to]!.kind != 'section') {
        (children[from] ??= []).add(to);
      }
    }

    final center = Offset(size.width / 2, size.height / 2);
    final span = math.min(size.width, size.height);
    final hubR = span * 0.30;
    const golden = 2.399963; // golden angle (rad)

    if (person != null) pos[person.id] = center;

    for (var i = 0; i < sections.length; i++) {
      final a = -math.pi / 2 + 2 * math.pi * i / math.max(sections.length, 1);
      final s = sections[i];
      final hub = center + Offset(math.cos(a), math.sin(a)) * hubR;
      pos[s.id] = hub;
      final kids = children[s.id] ?? const [];
      // Leaf spiral radius scales with the cluster size so big sections spread
      // out instead of piling up.
      final leafStep = span * 0.028;
      final leafBase = span * 0.055;
      for (var k = 0; k < kids.length; k++) {
        final la = a + golden * (k + 1);
        final lr = leafBase + leafStep * math.sqrt(k + 1);
        pos[kids[k]] = hub + Offset(math.cos(la), math.sin(la)) * lr;
      }
    }

    // Draw every edge whose endpoints both landed.
    for (final (f, t) in graph.edges) {
      if (pos.containsKey(f) && pos.containsKey(t)) edges.add((f, t));
    }
    // Clamp into the canvas with a small margin so nothing paints off-edge.
    final m = span * 0.03;
    for (final e in pos.entries) {
      pos[e.key] = Offset(
        e.value.dx.clamp(m, size.width - m),
        e.value.dy.clamp(m, size.height - m),
      );
    }
  }

  final PersonGraph graph;
  final Size size;
  final Map<String, Offset> pos = {};
  final List<(String, String)> edges = [];

  double radiusFor(GraphNode n) => switch (n.kind) {
        'person' => 17,
        'section' => 10,
        'report' => 8,
        'image' => 8,
        _ => 6,
      };

  /// The node nearest [p] within a finger-sized radius (leaves win ties so a
  /// leaf on top of a hub is still reachable).
  GraphNode? hit(Offset p) {
    GraphNode? best;
    var bestD = 26.0;
    for (final n in graph.nodes) {
      final o = pos[n.id];
      if (o == null) continue;
      final d = (o - p).distance;
      final within = d < bestD || (best != null && d < bestD + 6 && n.kind != 'section' && best.kind == 'section');
      if (within) {
        bestD = d;
        best = n;
      }
    }
    return best;
  }
}

class _NeuralPainter extends CustomPainter {
  _NeuralPainter({
    required this.layout,
    required this.ac,
    required this.selected,
    required this.pulse,
    required this.animate,
  });

  final _NeuralLayout layout;
  final AymaTokens ac;
  final String? selected;
  final double pulse; // 0..1
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    // Deep neural backdrop (consistent in light + dark) with a soft centre glow.
    final bgRect = Offset.zero & size;
    canvas.drawRect(
      bgRect,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF131A2E), Color(0xFF070A12)],
          radius: 0.9,
        ).createShader(bgRect),
    );

    final byId = {for (final n in layout.graph.nodes) n.id: n};
    final sel = selected;
    final selNeighbours = <String>{};
    if (sel != null) {
      selNeighbours.add(sel);
      for (final (f, t) in layout.edges) {
        if (f == sel) selNeighbours.add(t);
        if (t == sel) selNeighbours.add(f);
      }
    }

    // Synapses.
    for (final (f, t) in layout.edges) {
      final pa = layout.pos[f];
      final pb = layout.pos[t];
      if (pa == null || pb == null) continue;
      final incident = sel != null && (f == sel || t == sel);
      final ca = _GraphColors.forNode(ac, byId[f]!);
      final cb = _GraphColors.forNode(ac, byId[t]!);
      final paint = Paint()
        ..strokeWidth = incident ? 1.6 : 0.8
        ..shader = LinearGradient(colors: [
          ca.withValues(alpha: incident ? 0.75 : 0.16),
          cb.withValues(alpha: incident ? 0.75 : 0.16),
        ]).createShader(Rect.fromPoints(pa, pb));
      canvas.drawLine(pa, pb, paint);

      // A faint signal travelling the selected node's synapses.
      if (incident && animate) {
        final tphase = pulse;
        final p = Offset.lerp(pa, pb, tphase)!;
        canvas.drawCircle(p, 2.2, Paint()..color = cb.withValues(alpha: 0.9));
      }
    }

    // Neurons.
    for (final n in layout.graph.nodes) {
      final c = layout.pos[n.id];
      if (c == null) continue;
      final color = _GraphColors.forNode(ac, n);
      final r = layout.radiusFor(n);
      final focused = sel == null || selNeighbours.contains(n.id);
      final dim = sel != null && !focused;
      final coreColor = dim ? color.withValues(alpha: 0.28) : color;

      // Breathing halo.
      final haloT = animate ? (0.5 + 0.5 * pulse) : 0.75;
      final haloAlpha = (dim ? 0.05 : 0.18) * haloT;
      canvas.drawCircle(c, r * (1.9 + 0.4 * haloT), Paint()..color = color.withValues(alpha: haloAlpha));

      // Core, with a kind glyph.
      _paintNode(canvas, n, c, r, coreColor);

      if (n.id == sel) {
        canvas.drawCircle(
          c,
          r + 5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  void _paintNode(Canvas canvas, GraphNode n, Offset c, double r, Color color) {
    final fill = Paint()..color = color;
    switch (n.kind) {
      case 'report':
        // A filled ring — a "report" glyph.
        canvas.drawCircle(c, r, Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4);
        canvas.drawCircle(c, r * 0.42, fill);
        return;
      case 'image':
        // A rounded square — a "photo" glyph.
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: r * 1.7, height: r * 1.7),
          Radius.circular(r * 0.45),
        );
        canvas.drawRRect(rect, fill);
        return;
      case 'person':
        canvas.drawCircle(c, r, fill);
        canvas.drawCircle(c, r * 0.5, Paint()..color = Colors.white.withValues(alpha: 0.85));
        return;
      default:
        canvas.drawCircle(c, r, fill);
    }
  }

  @override
  bool shouldRepaint(_NeuralPainter old) =>
      old.pulse != pulse ||
      old.selected != selected ||
      old.layout != layout ||
      old.ac != ac;
}
