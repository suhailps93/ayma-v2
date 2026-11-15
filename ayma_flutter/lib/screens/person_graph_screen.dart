import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/bullet_visibility.dart';
import '../widgets/overflow_guards.dart';

/// "My person graph" — the person in the centre, their story sections around
/// them, and (once a section is tapped open) its bullets as leaves, coloured
/// by visibility. Tap a section to expand/collapse it; tap a bullet to read
/// its text and visibility. [uid] shows another member's graph (public
/// bullets only); null is the signed-in user's own.
class PersonGraphScreen extends StatefulWidget {
  const PersonGraphScreen({super.key, this.api, this.uid});

  static const path = '/profile/graph';

  final ApiClient? api;
  final String? uid;

  @override
  State<PersonGraphScreen> createState() => _PersonGraphScreenState();
}

class _PersonGraphScreenState extends State<PersonGraphScreen>
    with ScreenContextReasserter<PersonGraphScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  PersonGraph? _graph;
  String? _error;
  final Set<String> _expanded = {};
  String? _selected;

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    unawaited(_load());
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

  void _tap(String id, String kind) {
    setState(() {
      _selected = id;
      if (kind == 'section' && !_expanded.add(id)) _expanded.remove(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final g = _graph;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('My person graph'),
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
              expanded: _expanded,
              selected: _selected,
              onTap: _tap,
            ),
    );
  }
}

class _GraphBody extends StatelessWidget {
  const _GraphBody({
    required this.graph,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  final PersonGraph graph;
  final Set<String> expanded;
  final String? selected;
  final void Function(String id, String kind) onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final layout = _GraphLayout(graph, expanded);
    final sel = selected == null
        ? null
        : graph.nodes.where((n) => n.id == selected).firstOrNull;
    final sections = graph.nodes.where((n) => n.kind == 'section').toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final side = c.maxWidth.clamp(240.0, 520.0);
            return Center(
              child: SizedBox(
                width: side,
                height: side,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final hit = layout.hit(d.localPosition, Size(side, side));
                    if (hit != null) onTap(hit.id, hit.kind);
                  },
                  child: CustomPaint(
                    painter: _GraphPainter(layout, ac, selected),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        if (sel != null) _Detail(node: sel),
        const SizedBox(height: 8),
        for (final s in sections)
          ListTile(
            key: ValueKey('graph_section_${s.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            minVerticalPadding: 8,
            leading: Icon(
              expanded.contains(s.id) ? Icons.expand_less : Icons.expand_more,
              color: ac.fgDim,
            ),
            title: Text(s.label, style: AymaType.sans(size: 14, color: ac.fg)),
            subtitle: s.subtitle.isEmpty
                ? null
                : Text(s.subtitle, style: AymaType.sans(size: 12, color: ac.fgMute)),
            onTap: () => onTap(s.id, 'section'),
          ),
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.node});

  final GraphNode node;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isBullet = node.kind == 'bullet';
    final color = isBullet ? bulletVisibilityColor(ac, node.visibility) : ac.accent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.bgCard,
        border: Border.all(color: ac.lineSoft),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isBullet ? node.text : node.label,
            style: AymaType.sans(size: 15, color: ac.fg),
          ),
          if (isBullet)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(bulletVisibilityIcon(node.visibility), size: 14, color: color),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      bulletVisibilityLabel(node.visibility),
                      style: AymaType.sans(size: 12, color: color),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Positions in unit space (-1..1, centre 0,0): sections on a ring, each
/// expanded section's bullets on an arc just beyond it.
class _GraphLayout {
  _GraphLayout(PersonGraph g, Set<String> expanded) {
    final byId = {for (final n in g.nodes) n.id: n};
    final sections = g.nodes.where((n) => n.kind == 'section').toList();
    final children = <String, List<String>>{};
    for (final (from, to) in g.edges) {
      if (byId[from]?.kind == 'section' && byId[to]?.kind == 'bullet') {
        (children[from] ??= []).add(to);
      }
    }
    final center = g.nodes.where((n) => n.kind == 'person').firstOrNull;
    if (center != null) {
      pos[center.id] = Offset.zero;
      nodes.add(center);
    }
    for (var i = 0; i < sections.length; i++) {
      final a = -math.pi / 2 + 2 * math.pi * i / math.max(sections.length, 1);
      final s = sections[i];
      pos[s.id] = Offset(math.cos(a), math.sin(a)) * 0.5;
      nodes.add(s);
      if (!expanded.contains(s.id)) continue;
      final kids = children[s.id] ?? const [];
      final span = math.min(math.pi * 0.9, 0.32 * kids.length);
      for (var k = 0; k < kids.length; k++) {
        final ka = kids.length == 1
            ? a
            : a - span / 2 + span * k / (kids.length - 1);
        final b = byId[kids[k]]!;
        pos[b.id] = Offset(math.cos(ka), math.sin(ka)) * 0.86;
        nodes.add(b);
        edges.add((s.id, b.id));
      }
    }
    for (final s in sections) {
      if (center != null) edges.add((center.id, s.id));
    }
  }

  final Map<String, Offset> pos = {};
  final List<GraphNode> nodes = [];
  final List<(String, String)> edges = [];

  Offset toPx(Offset u, Size size) => Offset(
    size.width / 2 + u.dx * size.width / 2 * 0.9,
    size.height / 2 + u.dy * size.height / 2 * 0.9,
  );

  /// The node nearest [p] within a finger-sized radius, bullets first.
  GraphNode? hit(Offset p, Size size) {
    GraphNode? best;
    var bestD = 24.0;
    for (final n in nodes) {
      final d = (toPx(pos[n.id]!, size) - p).distance;
      if (d < bestD) {
        bestD = d;
        best = n;
      }
    }
    return best;
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.layout, this.ac, this.selected);

  final _GraphLayout layout;
  final AymaTokens ac;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = ac.line
      ..strokeWidth = 1;
    for (final (a, b) in layout.edges) {
      final pa = layout.pos[a];
      final pb = layout.pos[b];
      if (pa == null || pb == null) continue;
      canvas.drawLine(layout.toPx(pa, size), layout.toPx(pb, size), line);
    }
    for (final n in layout.nodes) {
      final c = layout.toPx(layout.pos[n.id]!, size);
      final (radius, color) = switch (n.kind) {
        'person' => (16.0, ac.accent),
        'section' => (9.0, ac.fgDim),
        _ => (6.0, bulletVisibilityColor(ac, n.visibility)),
      };
      canvas.drawCircle(c, radius, Paint()..color = color);
      if (n.id == selected) {
        canvas.drawCircle(
          c,
          radius + 4,
          Paint()
            ..color = ac.fg
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.layout != layout || old.selected != selected || old.ac != ac;
}
