/// The recursive person-graph node the [NodeVisualiser] renders — one data
/// model, one renderer, every surface (Your Story, public profile, every
/// report, the image carousel, the person-graph tap-detail).
///
/// This is the client side of the backend node-tree payload
/// (`person_graph_tree.node_tree`). A node carries its own content plus all its
/// child nodes recursively, so the visualiser renders a node and its whole
/// subtree from one object.
library;

/// Which surface a [NodeVisualiser] renders on. The ONLY behavioural
/// differences are the visibility filter (public profile shows public nodes
/// only) and whether the owner action bubbles appear (owner surfaces only).
enum NodeVisualiserSurface { story, publicProfile, report, graphDetail }

final RegExp _displayWordRe = RegExp(r"[a-z0-9]+(?:'[a-z]+)?");

/// The canonical, comparison-only form of a display string — lower-cased with
/// whitespace and punctuation collapsed, matching the backend dedupe normalizer
/// (`person_graph_index.normalize_text`). Used only to decide whether a node's
/// header (label/prompt/card title) and its body (text/answer/card body) are the
/// SAME statement, so a surface that renders both can show it once.
String normalizeForDisplayMatch(String s) =>
    _displayWordRe.allMatches(s.toLowerCase()).map((m) => m[0]).join(' ');

/// True when [header] and [body] are the same statement after normalization —
/// an emergent narrative node that stored its text in both the prompt and the
/// answer field (founder build 2493: the node context card printed the sentence
/// twice). A surface rendering both then shows the body once and drops the
/// duplicate header. Empty strings never match (nothing to collapse).
bool headerRestatesBody(String header, String body) {
  final h = normalizeForDisplayMatch(header);
  if (h.isEmpty) return false;
  return h == normalizeForDisplayMatch(body);
}

/// A node's visibility / a parent's subtree colour.
/// `public` = green, `private` = yellow, `ayma_only` = the AI-only colour,
/// `mixed` = a subtree holding both public and private (the split bullet).
class NodeVis {
  static const public = 'public';
  static const private = 'private';
  static const aymaOnly = 'ayma_only';
  static const mixed = 'mixed';
}

/// The fixed, versioned VISUAL palette (less-text-heavy Part 2). A node's
/// [NodeVisual.type] is one of these; the [NodeVisualiser] has exactly one thin
/// renderer per entry and dispatches on it. An unknown/absent type (a newer
/// server, a bad pick) renders as [gistRow] — the universal fallback — so a new
/// node of a known shape renders visually with ZERO new client code.
///
/// Mirrors `functions/bootstrap/node_visual.py` (PALETTE v1).
class NodeVisualType {
  static const gistRow = 'gist_row';
  static const chipSet = 'chip_set';
  static const timelineEntry = 'timeline_entry';
  static const barMeter = 'bar_meter';
  static const gauge = 'gauge';
  static const card = 'card';
  static const photoCarousel = 'photo_carousel';
  static const smallTable = 'small_table';
}

/// A node's write-time (or read-time default) visual descriptor:
/// `{type, params, v}` — the single thing the client palette reads to decide HOW
/// to draw a node. The UI is a thin renderer: it NEVER re-picks a visual, it only
/// reads this. See `docs/PERSON_GRAPH.md § Write-time visual pick` for the params
/// shape of each type.
class NodeVisual {
  const NodeVisual({required this.type, this.params = const {}, this.v = 1});

  /// One of [NodeVisualType]; any other string is treated as [NodeVisualType.gistRow].
  final String type;

  /// The type's parameters (items / date+title / value+min+max+label / … ) —
  /// read from EXACTLY the documented shape; a renderer with insufficient params
  /// falls back to the gist row.
  final Map<String, dynamic> params;

  /// Palette version (forward-compatibility marker).
  final int v;

  static NodeVisual? fromMap(dynamic m) {
    if (m is! Map) return null;
    final type = m['type'] as String?;
    if (type == null || type.isEmpty) return null;
    final rawParams = m['params'];
    return NodeVisual(
      type: type,
      params: rawParams is Map
          ? rawParams.map((k, v) => MapEntry(k.toString(), v))
          : const {},
      v: (m['v'] as num?)?.toInt() ?? 1,
    );
  }
}

/// One node of the person graph, with its children.
class StoryNode {
  const StoryNode({
    required this.id,
    required this.section,
    required this.label,
    required this.text,
    this.gist = '',
    required this.answerType,
    required this.level,
    required this.visibility,
    required this.subtreeVisibility,
    required this.standard,
    this.standardLabel,
    this.standardOrder,
    required this.editable,
    this.imageUrl = '',
    this.imageRead = '',
    this.isYou = 'unknown',
    this.sourceKind = '',
    this.sourceRef = '',
    this.sourceMessageId = '',
    this.sourceCreatedAt = '',
    this.statValue,
    this.statText = '',
    this.statBasis = '',
    this.linkUrl = '',
    this.linkPlatform = '',
    this.candidateId = '',
    this.dated = '',
    this.visual,
    this.children = const [],
  });

  final String id;
  final String section;

  /// The node's display label. For a standard field this is its field label
  /// ("Name", "Age"); otherwise the node's prompt.
  final String label;

  /// The node's value / content text. For an image node this is Ayma's read of
  /// the image.
  final String text;

  /// The GIST — a short punchy one-line headline for this node (less-text-heavy
  /// program, Part 1). Rendered BY DEFAULT in place of the full [text]; the full
  /// prose shows only on tap-in (the node chat window). The backend derives this
  /// for every node (stored writer gist if present, else a trimmed fallback of
  /// [text]), so it is normally non-empty for a text node; [displayGist] falls
  /// back to [text]/[label] when it isn't.
  final String gist;

  /// What a collapsed (default) node row shows: the [gist] when the backend
  /// supplied one, else the full [text], else the [label]. This is the single
  /// default/fallback render path Part 2's kind-keyed visual renderers wrap.
  String get displayGist =>
      gist.isNotEmpty ? gist : (text.isNotEmpty ? text : label);

  /// `image` for an image node, `narrative`/`bool`/… otherwise.
  final String answerType;

  /// Depth in the tree (1 = top level). Drives node SIZE in the person-graph
  /// view. It does NOT drive the [NodeVisualiser] list/tree indentation — that
  /// is by real depth under a true parent only, so a parentless conversational
  /// fact (stored at level 2) renders FLUSH at its section base rather than
  /// reading as a child of the standard item above it (founder build 2495).
  final int level;

  /// `public` | `private` | `ayma_only`.
  final String visibility;

  /// `public` | `private` | `ayma_only` | `mixed` — the bullet colour (a `mixed`
  /// subtree paints the split yin-yang bullet).
  final String subtreeVisibility;

  /// A known structured field (name/age/gender/…) — rendered as a labelled field.
  final bool standard;
  final String? standardLabel;
  final int? standardOrder;

  /// False for `ayma_only` (read-only) nodes — no owner action bubbles act on it.
  final bool editable;

  // --- image node (Contract 1) ---
  final String imageUrl;
  final String imageRead;

  /// `yes` | `no` | `unknown` — the structured is-you verdict.
  final String isYou;
  final String sourceKind;
  final String sourceRef;

  /// The exact chat message this node was captured from (founder Nov 17) — so
  /// tapping the node's source can open that conversation scrolled to it.
  final String sourceMessageId;
  final String sourceCreatedAt;

  // --- report node kinds (2o P0) ---
  /// `stat` node — the numeric score (0-10 or 0-100), or null for a
  /// non-numeric stat (a CONFIDENCE band, rendered as a pill from [statText]).
  final double? statValue;

  /// `stat` node — the raw value as text (the band label for a confidence
  /// stat, e.g. "Low"; the number as a string for a numeric one).
  final String statText;

  /// `stat` node — the basis line under the bar ("22% weight · measured").
  final String statBasis;

  /// `link` node — the destination URL.
  final String linkUrl;

  /// `link` node — a social platform key (instagram/x/linkedin/…) or ''.
  final String linkPlatform;

  /// `candidate` node — the reverse-image-search candidate id (is-me/not-me).
  final String candidateId;

  /// A date the node ALREADY carries (the first `Link.dated` on it), or `''`.
  /// The dedicated Career view renders it timeline-style where present and
  /// omits it where empty — no date is ever invented (founder Nov 17).
  final String dated;

  /// The write-time (or read-time default) VISUAL descriptor for this node — how
  /// the [NodeVisualiser] palette draws it (chip / timeline / bar / card / …).
  /// Null only for a locally-minted node ([StoryNode.image]); the backend tree
  /// always supplies one, and a null / unknown type renders as the gist row.
  final NodeVisual? visual;

  /// The palette type to render this node as — the stored/derived [visual] type,
  /// or [NodeVisualType.gistRow] when there is none.
  String get visualType => visual?.type ?? NodeVisualType.gistRow;

  final List<StoryNode> children;

  /// A minimal image node wrapping an already-curated photo URL — the profile
  /// photo carousel's pages (2o P4). The carousel's photos come from the
  /// profile's own curated set (public reads `photos` only), not the graph
  /// tree, so no read / is-you / provenance travels with them; the node exists
  /// only so the carousel renders each photo through the ONE shared
  /// [StoryNode]-based image-node renderer ([NodeImage]) instead of a bespoke
  /// second image widget.
  factory StoryNode.image({required String id, required String imageUrl}) =>
      StoryNode(
        id: id,
        section: '',
        label: '',
        text: '',
        answerType: 'image',
        level: 1,
        visibility: NodeVis.public,
        subtreeVisibility: NodeVis.public,
        standard: false,
        editable: false,
        imageUrl: imageUrl,
      );

  bool get isImage => answerType == 'image' && imageUrl.isNotEmpty;
  bool get isStat => answerType == 'stat';
  bool get isLink => answerType == 'link';
  bool get isCandidate => answerType == 'candidate' && imageUrl.isNotEmpty;

  factory StoryNode.fromMap(Map<String, dynamic> m) {
    return StoryNode(
      id: m['id'] as String? ?? '',
      section: m['section'] as String? ?? '',
      label: m['label'] as String? ?? '',
      text: m['text'] as String? ?? '',
      gist: m['gist'] as String? ?? '',
      answerType: m['answer_type'] as String? ?? 'text',
      level: (m['level'] as num?)?.toInt() ?? 1,
      visibility: m['visibility'] as String? ?? NodeVis.private,
      subtreeVisibility:
          m['subtree_visibility'] as String? ?? m['visibility'] as String? ?? NodeVis.private,
      standard: m['standard'] as bool? ?? false,
      standardLabel: m['standard_label'] as String?,
      standardOrder: (m['standard_order'] as num?)?.toInt(),
      editable: m['editable'] as bool? ?? true,
      imageUrl: m['image_url'] as String? ?? '',
      imageRead: m['image_read'] as String? ?? '',
      isYou: m['is_you'] as String? ?? 'unknown',
      sourceKind: m['source_kind'] as String? ?? '',
      sourceRef: m['source_ref'] as String? ?? '',
      sourceMessageId: m['source_message_id'] as String? ?? '',
      sourceCreatedAt: m['source_created_at'] as String? ?? '',
      statValue: (m['stat_value'] as num?)?.toDouble(),
      statText: m['stat_text'] as String? ?? '',
      statBasis: m['stat_basis'] as String? ?? '',
      linkUrl: m['link_url'] as String? ?? '',
      linkPlatform: m['link_platform'] as String? ?? '',
      candidateId: m['candidate_id'] as String? ?? '',
      dated: m['dated'] as String? ?? '',
      visual: NodeVisual.fromMap(m['visual']),
      children: ((m['children'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => StoryNode.fromMap(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  /// Every image node in this subtree (self + descendants), for the carousel.
  List<StoryNode> collectImages() {
    final out = <StoryNode>[];
    void walk(StoryNode n) {
      if (n.isImage) out.add(n);
      for (final c in n.children) {
        walk(c);
      }
    }

    walk(this);
    return out;
  }
}

/// One section group of root nodes in the tree payload.
class GraphTreeSection {
  const GraphTreeSection({
    required this.pageType,
    required this.title,
    required this.order,
    required this.nodes,
  });

  final String pageType;
  final String title;
  final int order;
  final List<StoryNode> nodes;

  factory GraphTreeSection.fromMap(Map<String, dynamic> m) => GraphTreeSection(
        pageType: m['page_type'] as String? ?? '',
        title: m['title'] as String? ?? '',
        order: (m['order'] as num?)?.toInt() ?? 0,
        nodes: ((m['nodes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => StoryNode.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// The whole Node-Visualiser tree payload (`GET /profile/graph/tree`, or a
/// report tree `GET /report/{type}/{id}/tree`).
class GraphTree {
  const GraphTree({
    required this.surface,
    required this.sections,
    this.title = '',
    this.meta = const {},
  });

  final String surface;
  final List<GraphTreeSection> sections;

  /// The report's title (report trees only; the person graph leaves it empty).
  /// Drives the pre-open summary card and any report header — the SAME tree the
  /// opened page renders, no separate store.
  final String title;

  /// The report tree's `meta` — `viewer_can_edit`, `created_at`/`updated_at`,
  /// `card_hidden_photos`, … carried through verbatim from `report_tree.py`.
  final Map<String, dynamic> meta;

  /// A human date line for this report (the run's `created_at`/`updated_at`/
  /// `as_of`/`date`), or `''` when the tree carries none. Never invented.
  String get reportDate {
    for (final k in const ['created_at', 'updated_at', 'as_of', 'date']) {
      final v = meta[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  /// Whether the signed-in viewer owns this report (owner affordances show only
  /// then). Reports default read-only unless `meta.viewer_can_edit` is true.
  bool get viewerCanEdit => meta['viewer_can_edit'] == true;

  /// Every image node across every section — the carousel's source.
  List<StoryNode> allImages() => [
        for (final s in sections)
          for (final n in s.nodes) ...n.collectImages(),
      ];

  factory GraphTree.fromMap(Map<String, dynamic> m) => GraphTree(
        surface: m['surface'] as String? ?? 'story',
        title: m['title'] as String? ?? '',
        meta: (m['meta'] is Map)
            ? (m['meta'] as Map).map((k, v) => MapEntry(k.toString(), v))
            : const {},
        sections: ((m['sections'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => GraphTreeSection.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );
}
