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

/// A node's visibility / a parent's subtree colour.
/// `public` = green, `private` = yellow, `ayma_only` = the AI-only colour,
/// `mixed` = a subtree holding both public and private (the split bullet).
class NodeVis {
  static const public = 'public';
  static const private = 'private';
  static const aymaOnly = 'ayma_only';
  static const mixed = 'mixed';
}

/// One node of the person graph, with its children.
class StoryNode {
  const StoryNode({
    required this.id,
    required this.section,
    required this.label,
    required this.text,
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

  /// `image` for an image node, `narrative`/`bool`/… otherwise.
  final String answerType;

  /// Depth in the tree — used only for the bullet indentation when a subtree is
  /// rendered standalone; children are normally indented relative to the parent.
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

/// The whole Node-Visualiser tree payload (`GET /profile/graph/tree`).
class GraphTree {
  const GraphTree({required this.surface, required this.sections});

  final String surface;
  final List<GraphTreeSection> sections;

  /// Every image node across every section — the carousel's source.
  List<StoryNode> allImages() => [
        for (final s in sections)
          for (final n in s.nodes) ...n.collectImages(),
      ];

  factory GraphTree.fromMap(Map<String, dynamic> m) => GraphTree(
        surface: m['surface'] as String? ?? 'story',
        sections: ((m['sections'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => GraphTreeSection.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );
}
