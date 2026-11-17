import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/node_chat_window.dart';
import '../widgets/node_visualiser.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/photo_gallery.dart';
import 'person_graph_layout.dart';

/// "My person graph" — a live, force-directed map of EVERYTHING the graph store
/// holds about the person (founder direction, Nov 16 2026). The person is the
/// largest node at the centre; sections are the next tier; every leaf — story
/// bullets, the Appearance and web-findings reports, photos, skills and Ayma's
/// assessment — is a smaller node whose SIZE encodes its depth and whose COLOUR
/// encodes its TYPE. The whole web settles live under link springs + node
/// repulsion, fits the screen, then stops. Pinch to zoom, two-finger-drag to
/// pan; a single-finger tap or drag (scrub) opens the node under the finger in
/// the visualiser below. Tapping lights up a node's ancestors, descendants and
/// related nodes; the rest dims.
/// [uid] shows another member's graph (public nodes only); null is the
/// signed-in user's own.

/// The route a tappable REPORT node pushes when its full content is opened, or
/// null when the node isn't a pushable report (images open a [PhotoViewer]
/// dialog instead; every other node just shows its detail in the visualiser).
/// Pure so the routing is unit-testable.
String? graphOpenRoute(GraphNode n) => switch (n.openType) {
      'appearance_report' =>
        '/appearance/${n.openId.isEmpty ? 'current' : n.openId}',
      'webfind_report' => n.openId.isEmpty ? null : '/deep-dive/${n.openId}',
      _ => null,
    };

/// Symmetric related-link adjacency (Track D, Contract 4) over the flat graph:
/// flat node id -> related flat ids. A link target is a raw graph-store id, but
/// a bullet is drawn as `b:<id>`, so each target is resolved to whichever flat
/// id actually exists; the result is symmetric so tapping either end lights the
/// other. Pure so the highlight wiring is unit-testable.
Map<String, Set<String>> buildRelatedAdjacency(
    Iterable<GraphNode> nodes, Set<String> existingIds) {
  String? resolve(String raw) {
    if (existingIds.contains(raw)) return raw;
    final prefixed = 'b:$raw';
    if (existingIds.contains(prefixed)) return prefixed;
    return null;
  }

  final adj = <String, Set<String>>{};
  for (final n in nodes) {
    for (final target in n.relatedTargets) {
      final t = resolve(target);
      if (t == null || t == n.id) continue;
      (adj[n.id] ??= {}).add(t);
      (adj[t] ??= {}).add(n.id);
    }
  }
  return adj;
}

/// The lit set when node [id] is tapped: the node, its ancestors, its
/// descendants, and its related nodes. Pure so the highlight is unit-testable.
Set<String> graphHighlightSet(
  String id, {
  required Map<String, Set<String>> parentsOf,
  required Map<String, Set<String>> childrenOf,
  required Map<String, Set<String>> relatedAdj,
}) {
  final out = <String>{id};
  // Ancestors.
  final up = <String>[id];
  var h = 0;
  while (h < up.length) {
    for (final p in parentsOf[up[h]] ?? const <String>{}) {
      if (out.add(p)) up.add(p);
    }
    h++;
  }
  // Descendants.
  final down = <String>[id];
  h = 0;
  while (h < down.length) {
    for (final c in childrenOf[down[h]] ?? const <String>{}) {
      if (out.add(c)) down.add(c);
    }
    h++;
  }
  out.addAll(relatedAdj[id] ?? const <String>{});
  return out;
}

/// The indexed StoryNode (Track B's tree) for a flat node id: the raw id, or a
/// bullet's `b:`-stripped id. Null when the tree holds no such node (a section
/// hub or the person centre, which the screen synthesizes). Pure for tests.
StoryNode? indexedStoryFor(String flatId, Map<String, StoryNode> storyById) {
  final direct = storyById[flatId];
  if (direct != null) return direct;
  if (flatId.startsWith('b:')) return storyById[flatId.substring(2)];
  return null;
}

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
                  Text(_error!, style: AymaType.sans(size: 14, color: ac.error)),
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
                  key: ValueKey(identityHashCode(g)),
                  graph: g,
                  api: _api,
                  uid: widget.uid,
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
                'Everything Ayma holds about you, wired together. Node size is '
                'depth, colour is type. Pinch to zoom, two fingers to pan. Tap '
                'or drag across a node to inspect it below.',
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
      ('Section', GraphTypeColors.section(ac)),
      ('Fact', GraphTypeColors.fact),
      ('Report', GraphTypeColors.report),
      ('Photo', GraphTypeColors.image),
      ('Skill', GraphTypeColors.skill),
      ("Ayma's read", GraphTypeColors.assess),
      ('Taste', GraphTypeColors.taste),
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
        Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: AymaType.sans(size: 12, color: ac.fgDim)),
      ],
    );
  }
}

/// Colour by TYPE for the graph (founder, Nov 17 2026: graph colour = type,
/// distinct from the visualiser where bullet colour = visibility). Facts carry
/// a dedicated type colour — the graph never colours a node by its visibility.
class GraphTypeColors {
  static const report = Color(0xFFE0A33E); // amber
  static const image = Color(0xFF4FC3D6); // cyan
  static const skill = Color(0xFF9B7BE0); // violet
  static const assess = Color(0xFFE07BB8); // magenta
  static const taste = Color(0xFF6FBF73); // green
  static const steering = Color(0xFFE08A5B); // orange
  static const interaction = Color(0xFF5B8AE0); // blue
  static const fact = Color(0xFF7E8CA8); // steel — a plain story fact
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
        _ => fact,
      };
}

/// The live graph: force simulation + fit + gestures + the visualiser below.
class _GraphBody extends StatefulWidget {
  const _GraphBody({
    super.key,
    required this.graph,
    required this.api,
    this.uid,
  });
  final PersonGraph graph;
  final ApiClient api;
  final String? uid;

  @override
  State<_GraphBody> createState() => _GraphBodyState();
}

class _GraphBodyState extends State<_GraphBody>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final GraphSim _sim;
  late final Map<String, GraphNode> _byId;
  late final Map<String, int> _levels;
  final Map<String, Set<String>> _childrenOf = {};
  final Map<String, Set<String>> _parentsOf = {};
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  final ViewTransform _view = ViewTransform.identity();

  Size _viewport = Size.zero;
  bool _userAdjusted = false; // once the user zooms/pans, auto-fit stops
  bool _reduceMotion = false;

  GraphNode? _selected;
  Set<String> _highlight = const {};

  // Track B's recursive tree, indexed by StoryNode id, fetched once on open.
  GraphTree? _tree;
  final Map<String, StoryNode> _storyById = {};

  // Symmetric related-link adjacency (Track D, Contract 4): flat id -> related
  // flat ids, resolved from every node's `links` (both directions).
  late final Map<String, Set<String>> _relatedAdj;

  bool get _isOwner => widget.uid == null;

  // Filters: hidden node kinds and hidden depth buckets.
  final Set<String> _hiddenKinds = {};
  final Set<int> _hiddenLevels = {};
  late final List<String> _kinds; // distinct kinds present, stable order
  late final List<int> _depths; // distinct depths present, ascending

  // Gesture bookkeeping.
  bool _multi = false;
  bool _multiInit = false;
  ViewTransform _startView = ViewTransform.identity();
  double _startGestureScale = 1;
  Offset _startFocalScene = Offset.zero;
  Offset _downPos = Offset.zero;
  double _maxMove = 0;

  static const double _minScale = 0.05;
  static const double _maxScale = 10;

  @override
  void initState() {
    super.initState();
    _byId = {for (final n in widget.graph.nodes) n.id: n};
    for (final (f, t) in widget.graph.edges) {
      if (_byId.containsKey(f) && _byId.containsKey(t)) {
        (_childrenOf[f] ??= {}).add(t);
        (_parentsOf[t] ??= {}).add(f);
      }
    }
    _levels = _computeLevels();
    _kinds = _distinctKinds();
    _depths = (_levels.values.toSet().toList()..sort());
    _relatedAdj =
        buildRelatedAdjacency(widget.graph.nodes, _byId.keys.toSet());

    final simNodes = [
      for (final n in widget.graph.nodes)
        SimNode(id: n.id, level: _levels[n.id] ?? 2),
    ];
    _sim = GraphSim(
      nodes: simNodes,
      edges: widget.graph.edges,
      centerId: _rootId(),
    );

    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      if (_reduceMotion) {
        _sim.settle();
        _fitToVisible();
        _repaint.value++;
      } else {
        _ticker.start();
      }
    });
    unawaited(_loadTree());
  }

  /// Fetch Track B's recursive tree ONCE and index every StoryNode by id, so a
  /// tap/scrub swaps the node prop cheaply (no per-node refetch). Best-effort:
  /// a failure leaves the detail panel on the synthesized fallback.
  Future<void> _loadTree() async {
    try {
      final tree =
          await widget.api.graphTree(uid: widget.uid, surface: 'graphDetail');
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _indexTree(tree);
      });
    } catch (_) {
      // Keep the graph usable; the panel falls back to the flat node content.
    }
  }

  void _indexTree(GraphTree tree) {
    _storyById.clear();
    void walk(StoryNode n) {
      _storyById[n.id] = n;
      for (final c in n.children) {
        walk(c);
      }
    }

    for (final s in tree.sections) {
      for (final n in s.nodes) {
        walk(n);
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  String? _rootId() {
    if (widget.graph.centerId.isNotEmpty &&
        _byId.containsKey(widget.graph.centerId)) {
      return widget.graph.centerId;
    }
    return widget.graph.nodes
        .where((n) => n.kind == 'person')
        .map((n) => n.id)
        .firstOrNull;
  }

  /// BFS depth from the person/centre over undirected edges. Unreached nodes
  /// fall back to a sensible depth by kind.
  Map<String, int> _computeLevels() {
    final root = _rootId();
    final level = <String, int>{};
    if (root != null) {
      level[root] = 0;
      final q = <String>[root];
      var head = 0;
      while (head < q.length) {
        final cur = q[head++];
        final d = level[cur]!;
        for (final nb in [
          ...?_childrenOf[cur],
          ...?_parentsOf[cur],
        ]) {
          if (!level.containsKey(nb)) {
            level[nb] = d + 1;
            q.add(nb);
          }
        }
      }
    }
    for (final n in widget.graph.nodes) {
      level.putIfAbsent(
          n.id,
          () => switch (n.kind) {
                'person' => 0,
                'section' => 1,
                _ => 2,
              });
    }
    return level;
  }

  List<String> _distinctKinds() {
    final seen = <String>{};
    final out = <String>[];
    for (final n in widget.graph.nodes) {
      final k = n.kind.isEmpty ? 'fact' : n.kind;
      if (seen.add(k)) out.add(k);
    }
    return out;
  }

  void _onTick(Duration _) {
    _sim.step();
    if (!_userAdjusted) _fitToVisible();
    _repaint.value++;
    if (_sim.isSettled) {
      _ticker.stop();
      if (!_userAdjusted) _fitToVisible();
      _repaint.value++;
    }
  }

  /// Fit the currently visible nodes into the viewport with padding.
  void _fitToVisible() {
    if (_viewport.width <= 0 || _viewport.height <= 0) return;
    final visible = _sim.nodes.where((s) => _passesFilter(s.id)).toList();
    final bounds = graphBounds(visible.isEmpty ? _sim.nodes : visible);
    final fit = fitToViewport(bounds, _viewport);
    _view.scale = fit.scale;
    _view.offset = fit.offset;
  }

  bool _passesFilter(String id) {
    final n = _byId[id];
    if (n == null) return false;
    final k = n.kind.isEmpty ? 'fact' : n.kind;
    if (_hiddenKinds.contains(k)) return false;
    if (_hiddenLevels.contains(_levels[id] ?? 2)) return false;
    return true;
  }

  // --- selection + highlight -------------------------------------------------

  void _select(GraphNode? n) {
    if (n?.id == _selected?.id) return;
    setState(() {
      _selected = n;
      _highlight = n == null
          ? const {}
          : graphHighlightSet(
              n.id,
              parentsOf: _parentsOf,
              childrenOf: _childrenOf,
              relatedAdj: _relatedAdj,
            );
    });
  }

  // --- hit testing -----------------------------------------------------------

  GraphNode? _hitTest(Offset viewportPoint) {
    final scene = _view.toScene(viewportPoint);
    // Touch tolerance (~22 logical px) expressed in scene units.
    final tol = 22 / _view.scale;
    GraphNode? best;
    var bestD = double.infinity;
    for (final s in _sim.nodes) {
      if (!_passesFilter(s.id)) continue;
      final d = (s.pos - scene).distance;
      final reach = math.max(s.radius, tol);
      if (d > reach) continue;
      // Nearer wins; on a near tie prefer the smaller (leaf) node so a leaf
      // sitting over a hub stays reachable.
      if (d < bestD - 0.5 ||
          (d < bestD + 0.5 && best != null && s.radius < _radiusOf(best))) {
        bestD = d;
        best = _byId[s.id];
      }
    }
    return best;
  }

  double _radiusOf(GraphNode n) => nodeRadiusForLevel(_levels[n.id] ?? 2);

  // --- gestures --------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails d) {
    _multi = false;
    _multiInit = false;
    _downPos = d.localFocalPoint;
    _maxMove = 0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _maxMove = math.max(_maxMove, (d.localFocalPoint - _downPos).distance);
    if (d.pointerCount >= 2) {
      _multi = true;
      _userAdjusted = true;
      if (!_multiInit) {
        _multiInit = true;
        _startView = ViewTransform(_view.scale, _view.offset);
        _startGestureScale = d.scale == 0 ? 1 : d.scale;
        _startFocalScene = _startView.toScene(d.localFocalPoint);
      }
      final factor = d.scale / _startGestureScale;
      final newScale =
          (_startView.scale * factor).clamp(_minScale, _maxScale).toDouble();
      _view.scale = newScale;
      // Keep the scene point under the (moving) focal fixed — this folds the
      // two-finger pan and the pinch zoom into one transform.
      _view.offset = d.localFocalPoint - _startFocalScene * newScale;
      _repaint.value++;
    } else if (!_multi) {
      // Single finger: scrub. Never pans. The node under the finger opens.
      final hit = _hitTest(d.localFocalPoint);
      if (hit != null) _select(hit);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (!_multi && _maxMove < 18) {
      // A clean single-finger tap: open the node, or clear on empty space.
      _select(_hitTest(_downPos));
    }
    _multi = false;
    _multiInit = false;
  }

  void _resetFit() {
    setState(() {
      _userAdjusted = false;
      _fitToVisible();
      _repaint.value++;
    });
  }

  void _toggleKind(String k) {
    setState(() {
      if (!_hiddenKinds.remove(k)) _hiddenKinds.add(k);
      _fitToVisible();
      _repaint.value++;
    });
  }

  void _toggleLevel(int lvl) {
    setState(() {
      if (!_hiddenLevels.remove(lvl)) _hiddenLevels.add(lvl);
      _fitToVisible();
      _repaint.value++;
    });
  }

  // --- detail (Track B NodeVisualiser) ---------------------------------------

  /// The StoryNode Track B's visualiser renders for a tapped flat node. The
  /// tree indexes raw ids; a bullet's flat id is `b:<raw>`, so try both, then
  /// fall back to a node synthesized from the flat node (a section hub shows its
  /// tree children; the person node shows its label) so the panel is never
  /// blank while the tree loads or for nodes the tree omits.
  StoryNode _storyFor(GraphNode n) {
    final indexed = indexedStoryFor(n.id, _storyById);
    if (indexed != null) return indexed;
    // Section hub: gather its section's root nodes from the tree as children.
    List<StoryNode> children = const [];
    if (n.kind == 'section' && _tree != null) {
      for (final s in _tree!.sections) {
        if (s.pageType == n.pageType) {
          children = s.nodes;
          break;
        }
      }
    }
    final vis = n.visibility.isEmpty ? NodeVis.private : n.visibility;
    return StoryNode(
      id: n.id,
      section: n.pageType,
      label: n.label,
      text: n.text,
      answerType: n.kind == 'image' ? 'image' : 'text',
      level: _levels[n.id] ?? 1,
      visibility: vis,
      subtreeVisibility: vis,
      standard: false,
      editable: vis != NodeVis.aymaOnly,
      imageUrl: n.imageUrl,
      imageRead: n.text,
      children: children,
    );
  }

  /// A node changed through the chat window — refetch the tree so the detail
  /// re-renders with the edit.
  void _onTreeChanged() => unawaited(_loadTree());

  /// The "Chat to edit" bubble hook — open the node chat window scoped to the
  /// node so the owner can edit it by chat.
  void _onChatToEdit(StoryNode n) {
    unawaited(showNodeChatWindow(
      context,
      node: n,
      surface: NodeVisualiserSurface.graphDetail,
      api: widget.api,
      isOwner: _isOwner,
    ).then((changed) {
      if (changed && mounted) _onTreeChanged();
    }));
  }

  // --- open full report / photo ----------------------------------------------

  void _openFull(GraphNode n) {
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
    if (route != null) context.push(route);
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // ChromeColumn caps the filter bar and the visualiser panel at their share
    // of the height and scrolls them in a short window, so the three stacked
    // regions can never add up past the column (layout matrix: 300px split,
    // text 2.0, keyboard up). The canvas keeps at least a quarter of the space.
    return ChromeColumn(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      headerShare: 0.3,
      footerShare: 0.45,
      header: [
        _FilterBar(
          kinds: _kinds,
          depths: _depths,
          hiddenKinds: _hiddenKinds,
          hiddenLevels: _hiddenLevels,
          onToggleKind: _toggleKind,
          onToggleLevel: _toggleLevel,
          onFit: _resetFit,
        ),
      ],
      body: LayoutBuilder(
        builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          if (size != _viewport) {
            _viewport = size;
            // Fit as soon as the viewport is known (and on size changes, until
            // the user takes over).
            if (!_userAdjusted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _fitToVisible();
                _repaint.value++;
              });
            }
          }
          return ClipRect(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              child: RepaintBoundary(
                child: CustomPaint(
                  size: size,
                  painter: _GraphPainter(
                    sim: _sim,
                    view: _view,
                    byId: _byId,
                    adjacency: _childrenOf,
                    ac: ac,
                    selectedId: _selected?.id,
                    highlight: _highlight,
                    passes: _passesFilter,
                    repaint: _repaint,
                  ),
                ),
              ),
            ),
          );
        },
      ),
      footer: [
        _VisualiserPanel(
          node: _selected,
          story: _selected == null ? null : _storyFor(_selected!),
          color: _selected == null
              ? ac.accent
              : GraphTypeColors.forNode(ac, _selected!),
          api: widget.api,
          isOwner: _isOwner,
          onOpenFull: _openFull,
          onChatToEdit: _onChatToEdit,
          onChanged: _onTreeChanged,
        ),
      ],
    );
  }
}

/// The always-visible one-tap filter controls: a type chip per kind present and
/// a depth chip per level present, plus a Fit button. Tapping a chip hides that
/// type/level (and its edges); tapping again restores it. Horizontal scroll so
/// it never overflows at small widths or large text scales.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.kinds,
    required this.depths,
    required this.hiddenKinds,
    required this.hiddenLevels,
    required this.onToggleKind,
    required this.onToggleLevel,
    required this.onFit,
  });

  final List<String> kinds;
  final List<int> depths;
  final Set<String> hiddenKinds;
  final Set<int> hiddenLevels;
  final void Function(String) onToggleKind;
  final void Function(int) onToggleLevel;
  final VoidCallback onFit;

  static String _kindLabel(String k) => switch (k) {
        'person' => 'You',
        'section' => 'Sections',
        'bullet' => 'Facts',
        'fact' => 'Facts',
        'report' => 'Reports',
        'image' => 'Photos',
        'skill' => 'Skills',
        'assess' => "Ayma's read",
        'taste' => 'Taste',
        'steering' => 'Steering',
        'interaction' => 'Chats',
        _ => k.isEmpty ? 'Other' : '${k[0].toUpperCase()}${k.substring(1)}',
      };

  static String _depthLabel(int d) => switch (d) {
        0 => 'Person',
        1 => 'Sections',
        _ => 'L$d',
      };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget chip(String label, Color color, bool on, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: on,
          showCheckmark: false,
          avatar: CircleAvatar(backgroundColor: color, radius: 6),
          labelStyle: AymaType.sans(
              size: 12, color: on ? ac.fg : ac.fgMute),
          backgroundColor: ac.bgCard,
          selectedColor: color.withValues(alpha: 0.18),
          side: BorderSide(color: on ? color.withValues(alpha: 0.5) : ac.lineSoft),
          onSelected: (_) => onTap(),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: ac.bg,
        border: Border(bottom: BorderSide(color: ac.lineSoft)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: onFit,
              icon: const Icon(Icons.fit_screen_outlined, size: 18),
              label: const Text('Fit'),
              style: TextButton.styleFrom(
                foregroundColor: ac.fgDim,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            for (final k in kinds)
              chip(_kindLabel(k), _kindColor(ac, k), !hiddenKinds.contains(k),
                  () => onToggleKind(k)),
            if (depths.length > 1) ...[
              const SizedBox(width: 4),
              for (final d in depths)
                chip(_depthLabel(d), ac.fgMute, !hiddenLevels.contains(d),
                    () => onToggleLevel(d)),
            ],
          ],
        ),
      ),
    );
  }

  static Color _kindColor(AymaTokens ac, String k) => switch (k) {
        'person' => ac.accent,
        'section' => GraphTypeColors.section(ac),
        'report' => GraphTypeColors.report,
        'image' => GraphTypeColors.image,
        'skill' => GraphTypeColors.skill,
        'assess' => GraphTypeColors.assess,
        'taste' => GraphTypeColors.taste,
        'steering' => GraphTypeColors.steering,
        'interaction' => GraphTypeColors.interaction,
        _ => GraphTypeColors.fact,
      };
}

/// The node visualiser below the graph — swaps its [node] as the finger taps or
/// scrubs. Hosts Track B's [NodeVisualiser] (Contract 3). An openable node
/// (report / photo) gets an "Open" affordance that pushes the full content.
class _VisualiserPanel extends StatelessWidget {
  const _VisualiserPanel({
    required this.node,
    required this.story,
    required this.color,
    required this.api,
    required this.isOwner,
    required this.onOpenFull,
    required this.onChatToEdit,
    required this.onChanged,
  });

  /// The tapped flat node — drives the header (type colour, label, "Open").
  final GraphNode? node;

  /// The recursive node Track B's visualiser renders (self + subtree).
  final StoryNode? story;
  final Color color;
  final ApiClient api;
  final bool isOwner;
  final void Function(GraphNode) onOpenFull;
  final void Function(StoryNode) onChatToEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final media = MediaQuery.of(context);
    final n = node;
    if (n == null || story == null) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + media.padding.bottom),
        decoration: BoxDecoration(
          color: ac.bgCard,
          border: Border(top: BorderSide(color: ac.lineSoft)),
        ),
        child: Text(
          'Tap or drag across a node to inspect it here.',
          style: AymaType.sans(size: 13, color: ac.fgMute),
        ),
      );
    }
    final panelMax = math.min(360.0, media.size.height * 0.45);
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: panelMax),
      decoration: BoxDecoration(
        color: ac.bgCard,
        border: Border(top: BorderSide(color: ac.lineSoft)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + media.padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  n.label.isEmpty ? n.kind : n.label,
                  style: AymaType.sans(size: 12, color: ac.fgDim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (n.isOpenable)
                TextButton(
                  onPressed: () => onOpenFull(n),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(48, 36),
                  ),
                  child: const Text('Open'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Track B's real recursive renderer (Contract 3), on the graph-detail
          // surface. Swapping `story` as the finger scrubs is a cheap prop
          // change — no heavy reload per node.
          Flexible(
            child: SingleChildScrollView(
              child: NodeVisualiser(
                node: story!,
                surface: NodeVisualiserSurface.graphDetail,
                api: api,
                isOwner: isOwner,
                onChanged: onChanged,
                onChatToEdit: onChatToEdit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the force-directed web in viewport space (scene points are mapped
/// through [view]). Edges are gentle, stably-arced splines so near-parallel
/// edges from a shared parent separate instead of stacking. Highlighted nodes
/// and their edges glow; the rest dims when something is selected. Repaints are
/// driven by [repaint] (the physics ticker), so frames cost no widget rebuild.
class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.sim,
    required this.view,
    required this.byId,
    required this.adjacency,
    required this.ac,
    required this.selectedId,
    required this.highlight,
    required this.passes,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GraphSim sim;
  final ViewTransform view;
  final Map<String, GraphNode> byId;

  /// Directed adjacency (parent -> children) for drawing edges.
  final Map<String, Set<String>> adjacency;
  final AymaTokens ac;
  final String? selectedId;
  final Set<String> highlight;
  final bool Function(String) passes;

  bool get _dimming => selectedId != null;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ac.bg);

    final posById = {for (final s in sim.nodes) s.id: s};

    // Edges first (dim pass, then lit pass on top).
    for (final pass in const [false, true]) {
      for (final s in sim.nodes) {
        final from = s.id;
        for (final to in adjacency[from] ?? const <String>{}) {
          if (!passes(from) || !passes(to)) continue;
          final lit = highlight.contains(from) && highlight.contains(to);
          if (lit != pass) continue;
          final a = posById[from];
          final b = posById[to];
          if (a == null || b == null) continue;
          _paintEdge(canvas, from, to, view.toViewport(a.pos),
              view.toViewport(b.pos), lit);
        }
      }
    }

    // Nodes (dim first, lit on top, the selected node last with a ring).
    for (final s in sim.nodes) {
      if (!passes(s.id)) continue;
      if (s.id == selectedId) continue;
      final lit = !_dimming || highlight.contains(s.id);
      if (lit) continue;
      _paintNode(canvas, s, false);
    }
    for (final s in sim.nodes) {
      if (!passes(s.id)) continue;
      if (s.id == selectedId) continue;
      final lit = !_dimming || highlight.contains(s.id);
      if (!lit) continue;
      _paintNode(canvas, s, true);
    }
    final sel = selectedId == null ? null : posById[selectedId];
    if (sel != null && passes(sel.id)) {
      _paintNode(canvas, sel, true);
      final c = view.toViewport(sel.pos);
      final r = sel.radius * view.scale + 5;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = ac.fg.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _paintEdge(
      Canvas canvas, String from, String to, Offset pa, Offset pb, bool lit) {
    final ca = GraphTypeColors.forNode(ac, byId[from]!);
    final cb = GraphTypeColors.forNode(ac, byId[to]!);
    final alpha = lit ? 0.8 : (_dimming ? 0.05 : 0.22);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lit ? 2.0 : 1.0
      ..shader = LinearGradient(colors: [
        ca.withValues(alpha: alpha),
        cb.withValues(alpha: alpha),
      ]).createShader(Rect.fromPoints(pa, pb));
    // Gentle, stable arc so near-parallel edges from a shared parent separate.
    final mid = Offset.lerp(pa, pb, 0.5)!;
    final d = pb - pa;
    final len = d.distance;
    if (len < 1e-3) return;
    final perp = Offset(-d.dy, d.dx) / len;
    final h = (from.hashCode ^ (to.hashCode * 31)) & 0x3ff;
    final signed = (h / 1023.0) * 2 - 1; // -1..1, stable per edge
    final bow = (len * 0.14 * signed).clamp(-30.0, 30.0);
    final control = mid + perp * bow;
    final path = Path()
      ..moveTo(pa.dx, pa.dy)
      ..quadraticBezierTo(control.dx, control.dy, pb.dx, pb.dy);
    canvas.drawPath(path, paint);
  }

  void _paintNode(Canvas canvas, SimNode s, bool lit) {
    final n = byId[s.id];
    if (n == null) return;
    final base = GraphTypeColors.forNode(ac, n);
    final color = lit ? base : base.withValues(alpha: 0.25);
    final c = view.toViewport(s.pos);
    final r = s.radius * view.scale;

    // Soft halo for the lit/selected nodes.
    if (lit) {
      canvas.drawCircle(
          c, r * 1.9, Paint()..color = base.withValues(alpha: 0.14));
    }

    final fill = Paint()..color = color;
    switch (n.kind) {
      case 'report':
        canvas.drawCircle(
            c,
            r,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1.4, r * 0.28));
        canvas.drawCircle(c, r * 0.42, fill);
        break;
      case 'image':
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: r * 1.7, height: r * 1.7),
          Radius.circular(r * 0.45),
        );
        canvas.drawRRect(rect, fill);
        break;
      case 'person':
        canvas.drawCircle(c, r, fill);
        canvas.drawCircle(
            c, r * 0.5, Paint()..color = Colors.white.withValues(alpha: 0.85));
        break;
      default:
        canvas.drawCircle(c, r, fill);
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.selectedId != selectedId ||
      old.highlight != highlight ||
      old.ac != ac;
}
