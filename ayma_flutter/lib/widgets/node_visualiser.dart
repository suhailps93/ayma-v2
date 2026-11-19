/// The ONE reusable renderer for a person-graph node and all its children.
///
/// One data model, one renderer: Your Story, the public profile, every report,
/// the image carousel and the person-graph tap-detail all render through this
/// widget. INPUT is a single [StoryNode]; it renders that node's content and
/// all of its child nodes recursively — each row indented ONLY by its real
/// depth under a TRUE PARENT in the render recursion, so a section member sits
/// FLUSH at the section base and a node nests only when it genuinely renders
/// under a parent. A node's stored [StoryNode.level] never indents it (founder
/// build 2495: a parentless level-2 fact must not read as a child of the
/// standard item above it). This removes the parallel-renderer defect class
/// structurally (founder Nov 16/17).
///
/// Rules folded in:
///  - FIXED ORDER + STANDARD fields: the backend tree already orders standard
///    (known structured) children first; a standard node renders as a labelled
///    field ("Name: …") rather than raw bullet text.
///  - IMAGE nodes render inline under their parent; tapping one opens the
///    partial node chat with its context (image + read + is-you verdict).
///  - VISIBILITY colours: every bullet is coloured by its (subtree) visibility
///    — green public, yellow private, AI-only third, split for a mixed subtree.
///  - VISIBILITY FILTER: the public-profile surface renders public nodes only;
///    every other (owner) surface renders what the tree carries.
///  - TAP-TO-CHAT: tapping a node opens the partial docked chat window directly
///    (no intermediate card) with the node as context; the owner action bubbles
///    live inside that chat. The bullets stay clean — no per-bullet icon
///    buttons.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../theme.dart';
import 'ayma_photo.dart';
import 'node_chat_window.dart';
import 'node_photo_carousel.dart';
import 'node_visibility.dart';
import 'score_bar.dart';

class NodeVisualiser extends StatelessWidget {
  const NodeVisualiser({
    super.key,
    required this.node,
    required this.surface,
    this.onChanged,
    this.api,
    this.isOwner = true,
    this.onImageTap,
    this.onCandidateVerdict,
    this.depth = 0,
  });

  /// The node to render (plus all of its children, recursively).
  final StoryNode node;

  /// The surface this renders on — sets the visibility filter and whether the
  /// owner action bubbles appear.
  final NodeVisualiserSurface surface;

  /// Called after a node changed through the chat window (visibility / text /
  /// delete / add-child), so the host can refresh its tree.
  final VoidCallback? onChanged;

  /// The API client for the action bubbles (defaults to a fresh [ApiClient]).
  final ApiClient? api;

  /// Whether the viewer owns this graph (owner action bubbles show only then).
  final bool isOwner;


  /// Overrides what tapping an image node does (the carousel passes its own
  /// viewer); defaults to opening the node chat window.
  final void Function(StoryNode node)? onImageTap;

  /// Handler for a CANDIDATE node's "This is me" / "Not me" verdict (the
  /// deep-dive report provides it). When null the two buttons are hidden and
  /// the candidate shows as a plain pending photo.
  final void Function(StoryNode node, bool isMe)? onCandidateVerdict;

  /// Render depth — how many TRUE PARENTS this node sits under in the render
  /// recursion. A section member (a section root) renders at depth 0 and so
  /// sits FLUSH at the section base; each real child renders one deeper. This
  /// is the ONLY thing that drives indentation. Hosts (a section list) leave
  /// it 0.
  final int depth;

  /// One indent step, in dp, per level of TRUE parentage.
  static const double _indentStep = 18;

  /// The deepest nesting that still earns a fresh indent step. Past this, every
  /// deeper node shares the same inset and the content text wraps instead, so
  /// deep nesting can't push a row off-screen at phone width / large text scale.
  static const int _maxIndentSteps = 5;

  /// Indent steps for this node: its real depth under a TRUE PARENT in the
  /// render recursion ([depth]) — a section member sits FLUSH at the section
  /// base (depth 0) and a node indents only when it renders UNDER a real parent
  /// (depth > 0). Capped at [_maxIndentSteps].
  ///
  /// [StoryNode.level] NEVER drives this. A conversational/editor fact stored
  /// at level 2 with NO parent is a FLAT section root; indenting it by level
  /// pushed it one step in and read as a child of whatever standard item
  /// preceded it (founder build 2495 — "this indentation does not make sense").
  /// Level still drives node SIZE in the person-graph view; that is a separate
  /// surface and is unaffected here.
  int get _indentSteps {
    if (depth < 0) return 0;
    return depth > _maxIndentSteps ? _maxIndentSteps : depth;
  }

  /// The fixed per-field ICON for a STANDARD (predefined) field, keyed by the
  /// node's field id — the SAME icon wherever the field appears (Your Story and
  /// the public profile). A standard field renders ICON + value with NO word
  /// label (founder build 2502: "Name: Suhail" → a person glyph + "Suhail"),
  /// the icon carrying the node's visibility colour so privacy reads at a
  /// glance. A field with no entry here keeps its visibility bullet and shows
  /// the value alone (no confusing glyph). The registry mirrors
  /// `person_graph.STANDARD_FIELDS`; extend both together when a new structured
  /// field is added.
  static const Map<String, IconData> _standardFieldIcons = {
    'legal_first_name': Icons.person_outline, // Name
    'date_of_birth': Icons.cake_outlined, // Age / date of birth
    'gender_identity': Icons.wc_outlined, // Gender
    'primary_location': Icons.location_on_outlined, // Location (pin)
    'target_match_genders': Icons.favorite_border, // Interested in (heart)
    'ethnic_cultural_origin': Icons.public_outlined, // Ethnic & cultural origin
    // What I'm Looking For (founder build 2507) — each keeps its "label: value"
    // (see [_labeledStandardFields]); the icon reads clearly and carries the
    // visibility colour like every other standard-field icon.
    'relocation_radius': Icons.radar_outlined, // travel / move radius
    'geographic_flexibility': Icons.flight_takeoff_outlined, // relocate abroad
  };

  /// Standard fields that render their field LABEL in front of the value
  /// ("`<label>: <value>`") instead of the icon-plus-bare-value of About Me —
  /// the What I'm Looking For rows, whose values are ambiguous on their own
  /// (founder build 2507: "Within about 50 km" needs its label). Keyed on the
  /// standard field id, so the same rule applies for EVERY user graph. The
  /// partner-age combined row keeps its label through its own range renderer
  /// (see [_rangePairIcons]).
  static const Set<String> _labeledStandardFields = {
    'relocation_radius',
    'geographic_flexibility',
  };

  /// The fixed icon for a `<base>_min`/`<base>_max` COMBINED range row, keyed on
  /// the pair BASE (the row is synthesized from two nodes, so it has no single
  /// standard id to key on). The icon carries the row's visibility colour, the
  /// same treatment as a standard-field icon. A base with no entry keeps the
  /// visibility bullet.
  static const Map<String, IconData> _rangePairIcons = {
    'partner_age': Icons.groups_outlined, // Partner age preference (people/range)
  };

  /// This node's standard-field icon, or null when it is not a standard field
  /// (prose/conversational nodes keep their coloured bullet) or no icon reads
  /// clearly for it.
  IconData? get _standardIcon =>
      node.standard ? _standardFieldIcons[node.id] : null;

  bool get _publicOnly => surface == NodeVisualiserSurface.publicProfile;

  bool _visible(String vis) => _publicOnly ? vis == NodeVis.public : true;

  bool _hasVisibleContent(StoryNode n) => _hasVisibleContentFor(n, _publicOnly);

  Future<void> _openChat(BuildContext context) => _openChatFor(context, node);

  /// Open the partial node chat (the SAME owner controls as a bullet — Make
  /// public / private, Edit manually, Chat to edit, Delete) for ANY node. Every
  /// palette visual — a chip, a timeline entry, a bar, a card, a table row —
  /// routes its tap here with its OWN node, so no visual can swallow the tap or
  /// strip the controls.
  Future<void> _openChatFor(BuildContext context, StoryNode target) =>
      _openNodeChat(context, target, _cfg);

  @override
  Widget build(BuildContext context) {
    final showOwnRow = _visible(node.visibility) && _nodeHasOwnContent(node);
    final visibleChildren =
        node.children.where(_hasVisibleContent).toList(growable: false);

    if (!showOwnRow && visibleChildren.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showOwnRow) _row(context),
        // Children render through the shared sibling renderer, which groups
        // consecutive LEAF siblings sharing an aggregating visual (chip_set /
        // timeline_entry) into ONE visual. The group is built ONLY from the
        // already visibility-filtered [visibleChildren], so a shared/public
        // surface NEVER aggregates a private or Ayma-only node into the set, and
        // deleting a node drops it from the set in the same render pass.
        ..._siblingWidgets(
          context,
          visibleChildren,
          _cfg,
          indentStart: (_indentSteps + 1).clamp(0, _maxIndentSteps) * _indentStep,
          depth: depth + 1,
        ),
      ],
    );
  }

  /// This renderer's config, carried to the shared sibling/aggregate helpers so a
  /// chip / timeline entry opens the SAME node chat + owner controls as a row.
  _NvCfg get _cfg => _NvCfg(
        surface: surface,
        api: api,
        isOwner: isOwner,
        onChanged: onChanged,
        onImageTap: onImageTap,
        onCandidateVerdict: onCandidateVerdict,
      );

  Widget _row(BuildContext context) {
    // A STANDARD field shows a fixed per-field ICON coloured by its visibility
    // (never a `mixed` leaf, so the single-colour icon is safe); every other
    // node — and a standard field with no fitting icon — keeps the coloured
    // visibility bullet.
    final icon =
        node.subtreeVisibility != NodeVis.mixed ? _standardIcon : null;
    final Widget leading = icon != null
        ? Icon(icon,
            key: Key('node_field_icon_${node.id}'),
            size: 18,
            color: nodeVisibilityColor(node.subtreeVisibility))
        : NodeVisibilityBullet(visibility: node.subtreeVisibility);
    // EdgeInsetsDirectional so the indent follows text direction — it grows
    // from the left in LTR and from the right in RTL.
    return Padding(
      padding: EdgeInsetsDirectional.only(start: _indentSteps * _indentStep),
      child: InkWell(
        key: Key('node_row_${node.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openChat(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fixed-width leading slot so an icon field (18) and a bullet
              // field (10) start the TEXT column at the SAME x — one text
              // column, not two (founder build 2509 screenshot). The glyph
              // top-aligns with the first text line (icons sit a touch higher
              // than the round bullet).
              SizedBox(
                width: 18,
                child: Padding(
                  padding: EdgeInsets.only(top: icon != null ? 2 : 6),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    child: leading,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _content(context)),
            ],
          ),
        ),
      ),
    );
  }

  /// The ONE palette dispatch (less-text-heavy Part 2): a single switch on
  /// [StoryNode.visualType] drives how a node draws — there is NO per-section or
  /// per-report presentation branching anywhere else. Each case reads EXACTLY
  /// the documented params shape; a case with insufficient params, and an
  /// unknown/absent type, fall through to the gist row (the universal fallback).
  /// A new node carrying a known type renders with zero new code.
  Widget _content(BuildContext context) {
    switch (node.visualType) {
      case NodeVisualType.chipSet:
        final w = _chipSetContent(context);
        if (w != null) return w;
        break;
      case NodeVisualType.timelineEntry:
        final w = _timelineContent(context);
        if (w != null) return w;
        break;
      case NodeVisualType.barMeter:
      case NodeVisualType.gauge:
        final w = _barContent(context,
            gauge: node.visualType == NodeVisualType.gauge);
        if (w != null) return w;
        break;
      case NodeVisualType.card:
        final w = _cardContent(context);
        if (w != null) return w;
        break;
      case NodeVisualType.smallTable:
        final w = _tableContent(context);
        if (w != null) return w;
        break;
      case NodeVisualType.photoCarousel:
        if (node.isImage) return _imageContent(context);
        break;
      // gist_row and any unknown type fall through to the gist-row fallback.
    }
    return _fallbackContent(context);
  }

  /// The gist-row fallback — the universal renderer. Also the home of the
  /// pre-existing node KINDS (candidate / image / stat / link) that predate the
  /// palette; a node whose palette type didn't render (unknown or short on
  /// params) lands here and still draws correctly, never raw JSON, never a crash.
  Widget _fallbackContent(BuildContext context) {
    if (node.isCandidate) return _candidateContent(context);
    if (node.isImage) return _imageContent(context);
    if (node.isStat) return _statContent(context);
    if (node.isLink) return _linkContent(context);
    final theme = Theme.of(context);
    // GIST-FIRST (less-text-heavy Part 1): the collapsed row shows the short
    // gist line, not the full prose. Tapping the row (see [_openChat]) opens the
    // node chat window, which carries the full [text]. The gist WRAPS to its
    // full length — a body/gist line is NEVER chopped mid-sentence (founder
    // build 2495: "no text should cut off partially"). The gist is written
    // short (build 2493), so a wrapped row stays compact; a genuinely long one
    // still renders in full rather than ending in "…".
    // A STANDARD (predefined) field normally renders its VALUE with NO word
    // label — the per-field icon in [_row] carries the meaning and the
    // visibility colour (founder build 2502). The What I'm Looking For standard
    // fields are the exception: their values are ambiguous alone, so they keep
    // "`<label>: <value>`" in front of the icon (founder build 2507). A
    // conversational/prose node has no standard label and renders the value line
    // under its coloured bullet.
    if (node.standard && _labeledStandardFields.contains(node.id)) {
      final label = (node.standardLabel ?? node.label).trim();
      if (label.isNotEmpty) {
        return RichText(
          text: TextSpan(
            style: theme.textTheme.bodyLarge,
            children: [
              TextSpan(
                text: '$label: ',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: node.displayGist),
            ],
          ),
        );
      }
    }
    return Text(
      node.displayGist,
      style: theme.textTheme.bodyLarge,
    );
  }

  Widget _imageContent(BuildContext context) => NodeImage(node: node);

  // --- palette renderers (less-text-heavy Part 2) ----------------------------
  // One thin renderer per palette entry, each reading EXACTLY the documented
  // params shape (docs/PERSON_GRAPH.md § Write-time visual pick) and returning
  // null on insufficient params so the dispatch falls back to the gist row. The
  // chip + timeline builders are shared with the sibling aggregate (top-level
  // `_chipWidget` / `_timelineRowWidget`), so a lone node and a merged set match.

  /// `chip_set` (single node) — this node's items as tappable chips. Null when
  /// there are no items (→ gist-row fallback). Shares the chip builder with the
  /// sibling aggregate so a lone chip and a merged set look identical.
  Widget? _chipSetContent(BuildContext context) {
    final items = _chipItemsOf(node);
    if (items.isEmpty) return null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < items.length; i++)
          _chipWidget(context, items[i], node, i, _cfg),
      ],
    );
  }

  /// `timeline_entry` (single node) — one dated entry on its own rail. Null when
  /// it has no title (→ fallback).
  Widget? _timelineContent(BuildContext context) {
    if (_timelineTitleOf(node).isEmpty) return null;
    return _timelineRowWidget(context, node, _cfg, first: true);
  }

  /// `bar_meter` / `gauge` — a labelled bar from `params.value,min,max,label`.
  /// Null when there is no numeric value (→ fallback). The row tap (the
  /// enclosing [_row] InkWell) opens this node's controls.
  Widget? _barContent(BuildContext context, {required bool gauge}) {
    final p = node.visual?.params ?? const {};
    final value = (p['value'] as num?)?.toDouble();
    if (value == null) return null;
    final lo = (p['min'] as num?)?.toDouble() ?? 0.0;
    final hiRaw = (p['max'] as num?)?.toDouble() ?? (value > 10 ? 100.0 : 10.0);
    final hi = hiRaw > lo ? hiRaw : lo + 1.0;
    final label = (p['label'] as Object?)?.toString() ?? '';
    final frac = ((value - lo) / (hi - lo)).clamp(0.0, 1.0);
    final ac = context.ac;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              // The bar's label/gist WRAPS in full — never chopped mid-sentence
              // (founder build 2495). The value sits to its right; a long label
              // wraps and the numeric readout stays put.
              child: Text(label.isNotEmpty ? label : node.displayGist,
                  style: theme.textTheme.bodyLarge),
            ),
            const SizedBox(width: 8),
            Text(_trimNum(value),
                key: Key('node_bar_value_${node.id}'),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ScoreBar(
            key: Key(
                '${gauge ? 'node_gauge' : 'node_bar'}_${node.id}'),
            value: frac * 10,
            max: 10,
            colorFor: (ctx, v, m) => _bandColor(ac, frac),
          ),
        ),
      ],
    );
  }

  /// `card` — a finding card from `params.title` + `params.body`. Null when both
  /// are empty (→ fallback).
  Widget? _cardContent(BuildContext context) {
    final p = node.visual?.params ?? const {};
    final title = (p['title'] as Object?)?.toString().trim() ?? '';
    final body = (p['body'] as Object?)?.toString().trim() ?? '';
    if (title.isEmpty && body.isEmpty) return null;
    // When the card title merely restates its body (a node that stored the same
    // statement in both fields — founder build 2493), show it once: keep the
    // body, drop the duplicate title.
    final showTitle = title.isNotEmpty && !headerRestatesBody(title, body);
    final ac = context.ac;
    final theme = Theme.of(context);
    return Container(
      key: Key('node_card_${node.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.fgDim.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.fgDim.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTitle)
            Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          if (showTitle && body.isNotEmpty) const SizedBox(height: 4),
          if (body.isNotEmpty)
            Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  /// `small_table` — a compact table from `params.columns,rows`. Each data row
  /// taps to this node's controls. Null when there are no rows (→ fallback).
  Widget? _tableContent(BuildContext context) {
    final p = node.visual?.params ?? const {};
    final columns = (p['columns'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];
    final rows = (p['rows'] as List?)
            ?.whereType<List>()
            .map((r) => r.map((e) => e.toString()).toList(growable: false))
            .toList(growable: false) ??
        const <List<String>>[];
    if (rows.isEmpty) return null;
    final ac = context.ac;
    final theme = Theme.of(context);
    // A small_table cell is a FIXED column slot of genuine tabular data (short
    // values, not prose) — an unbounded cell would misalign the whole grid, so
    // the cap stays here by design (founder build 2495: body/gist text wraps in
    // full; a strict fixed slot like a table cell may keep a clean cap).
    Widget cell(String s, {bool head = false}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(s,
                style: head
                    ? theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700)
                    : theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        );
    return Container(
      key: Key('node_table_${node.id}'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ac.fgDim.withValues(alpha: 0.18)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (columns.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: ac.fgDim.withValues(alpha: 0.06),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(10)),
              ),
              child: Row(children: [for (final c in columns) cell(c, head: true)]),
            ),
          for (var i = 0; i < rows.length; i++)
            InkWell(
              key: Key('node_table_row_${node.id}_$i'),
              onTap: () => _openChatFor(context, node),
              child: Row(children: [for (final c in rows[i]) cell(c)]),
            ),
        ],
      ),
    );
  }

  // --- report node kinds (2o P0) ---

  /// A SCORE / STAT node (numeric → label + value digit + banded ScoreBar), or
  /// a CONFIDENCE node (non-numeric → label + a band pill). [statBasis] reads
  /// as the quiet line under either.
  Widget _statContent(BuildContext context) {
    final theme = Theme.of(context);
    final ac = context.ac;
    final numeric = node.statValue != null;
    final max = numeric && node.statValue! > 10 ? 100.0 : 10.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          // A numeric value shares a text baseline with the label; the
          // confidence PILL has none, so baseline-aligning it floated the chip
          // against the card edge (founder build 2495). The pill row aligns on
          // the centre and lays the pill out INLINE (Flexible, not a right-
          // anchored chip), so it never overlaps the card border.
          crossAxisAlignment:
              numeric ? CrossAxisAlignment.baseline : CrossAxisAlignment.center,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(node.label.isNotEmpty ? node.label : node.text,
                  style: theme.textTheme.bodyLarge),
            ),
            const SizedBox(width: 8),
            if (numeric)
              Text(
                _trimNum(node.statValue!),
                key: Key('node_stat_value_${node.id}'),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              )
            else
              Flexible(child: _bandPill(context, node.statText)),
          ],
        ),
        if (numeric)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ScoreBar(
              key: Key('node_stat_bar_${node.id}'),
              value: node.statValue!,
              max: max,
              colorFor: (ctx, v, m) => _bandColor(ac, m <= 0 ? 0 : v / m),
            ),
          ),
        if (node.statBasis.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(node.statBasis,
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
          ),
      ],
    );
  }

  Widget _bandPill(BuildContext context, String text) {
    final ac = context.ac;
    return Container(
      key: Key('node_band_${node.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: _confidenceColor(ac, text).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: AymaType.mono(size: 11, color: _confidenceColor(ac, text))),
    );
  }

  // Same green/amber/red bands the report score bars use (contrast-safe *Text
  // tokens for the bar fill; the solid tokens for the pill).
  Color _bandColor(AymaTokens ac, double frac) {
    if (frac >= 0.7) return ac.successText;
    if (frac >= 0.4) return ac.warningText;
    return ac.errorText;
  }

  Color _confidenceColor(AymaTokens ac, String band) {
    switch (band.toLowerCase()) {
      case 'high':
        return ac.success;
      case 'medium':
        return ac.warning;
      case 'low':
        return ac.error;
      default:
        return ac.fgDim;
    }
  }

  static String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static IconData _platformIcon(String platform) => switch (platform) {
        'linkedin' => Icons.work_outline,
        'github' => Icons.code,
        'youtube' => Icons.play_circle_outline,
        '' => Icons.open_in_new,
        _ => Icons.link,
      };

  /// A LINK node — the label (or host) with a social/open glyph; the row tap
  /// (see [_openChat]) opens the URL.
  Widget _linkContent(BuildContext context) {
    final theme = Theme.of(context);
    final ac = context.ac;
    final label = node.label.isNotEmpty ? node.label : node.linkUrl;
    return Row(
      children: [
        Icon(_platformIcon(node.linkPlatform), size: 18, color: ac.fgDim),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(decoration: TextDecoration.underline)),
        ),
      ],
    );
  }

  /// A CANDIDATE node — a pending reverse-image-search photo with "This is me"
  /// / "Not me" when [onCandidateVerdict] is wired (the deep-dive report wires
  /// it); otherwise just the photo + caption.
  Widget _candidateContent(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 1,
              child: AymaPhoto(
                key: Key('node_candidate_${node.id}'),
                url: node.imageUrl,
                displayWidth: 400,
                // An unrenderable candidate shows a clean source fallback,
                // never a broken-image glyph (Leg 33).
                error: nodeImageSourceFallback(context, node),
              ),
            ),
          ),
        ),
        if (node.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child:
                Text(node.text, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (onCandidateVerdict != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            // `Wrap` (not a `Row`) so the two verdict buttons flow onto a
            // second line on a narrow/scaled viewport instead of overflowing.
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  key: Key('node_candidate_me_${node.id}'),
                  onPressed: () => onCandidateVerdict!(node, true),
                  child: const Text('This is me'),
                ),
                OutlinedButton(
                  key: Key('node_candidate_notme_${node.id}'),
                  onPressed: () => onCandidateVerdict!(node, false),
                  child: Text('Not me',
                      style: TextStyle(color: ac.fgDim)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Renders a whole [GraphTreeSection] (its root nodes in fixed order) — the
/// convenience a section-list surface (Your Story, a report) uses. Each root
/// node still renders through [NodeVisualiser], so there is one renderer.
class NodeVisualiserSection extends StatelessWidget {
  const NodeVisualiserSection({
    super.key,
    required this.section,
    required this.surface,
    this.onChanged,
    this.api,
    this.isOwner = true,
    this.onImageTap,
    this.onCandidateVerdict,
    this.cardStyle = false,
  });

  final GraphTreeSection section;
  final NodeVisualiserSurface surface;
  final VoidCallback? onChanged;
  final ApiClient? api;
  final bool isOwner;
  final void Function(StoryNode node)? onImageTap;
  final void Function(StoryNode node, bool isMe)? onCandidateVerdict;

  /// Render as a DESIGNED report section card — a soft elevated rounded panel
  /// with a serif heading — instead of the plain Your-Story heading + rows. The
  /// report framework host ([GraphTreeView] on the report surface) passes this,
  /// so every report's sections share the same visual-first card look. Your
  /// Story / public-profile / graph-detail leave it false (unchanged).
  final bool cardStyle;

  @override
  Widget build(BuildContext context) {
    final publicOnly = surface == NodeVisualiserSurface.publicProfile;
    // Visibility-filter the section's roots BEFORE grouping, so a sibling
    // aggregate (chip set / timeline) on a shared surface never merges a node
    // the viewer may not see (founder P0). The non-aggregated nodes still render
    // through [NodeVisualiser], which re-applies the same filter.
    final visible = section.nodes
        .where((n) => _hasVisibleContentFor(n, publicOnly))
        .toList(growable: false);
    // A section whose every node filtered out (all private on a shared surface,
    // or all empty) renders nothing — never an empty titled card.
    if (visible.isEmpty) return const SizedBox.shrink();

    final cfg = _NvCfg(
      surface: surface,
      api: api,
      isOwner: isOwner,
      onChanged: onChanged,
      onImageTap: onImageTap,
      onCandidateVerdict: onCandidateVerdict,
    );
    final body = _siblingWidgets(
      context,
      visible,
      cfg,
      indentStart: 0,
      depth: 0,
    );

    if (cardStyle) {
      final ac = context.ac;
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ac.lineSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (section.title.isNotEmpty)
              Semantics(
                header: true,
                child: Text(section.title,
                    style: AymaType.serif(size: 22, color: ac.fg)),
              ),
            if (section.title.isNotEmpty) const SizedBox(height: 8),
            ...body,
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (section.title.isNotEmpty)
          // 8pt rhythm: a 16 break above each section header (clear section
          // separation) and 8 below it to the first row, descending cleanly to
          // the 8 between-row gaps.
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              section.title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ...body,
      ],
    );
  }
}

// --- shared sibling + aggregate rendering ----------------------------------
// One place groups a visibility-filtered list of sibling nodes and renders each
// group. Used by BOTH the recursive [NodeVisualiser] (a node's children) and
// [NodeVisualiserSection] (a section's roots), so chip sets and timelines
// aggregate identically wherever siblings sit, and every chip / entry opens the
// SAME node chat + owner controls as a bullet row.

/// The config a chip / timeline entry needs to open its own node's chat.
class _NvCfg {
  const _NvCfg({
    required this.surface,
    this.api,
    this.isOwner = true,
    this.onChanged,
    this.onImageTap,
    this.onCandidateVerdict,
  });

  final NodeVisualiserSurface surface;
  final ApiClient? api;
  final bool isOwner;
  final VoidCallback? onChanged;
  final void Function(StoryNode node)? onImageTap;
  final void Function(StoryNode node, bool isMe)? onCandidateVerdict;
}

/// Whether a node has its own renderable content — text, an image, OR a visual
/// whose params carry something to draw (a node can be gist/text-empty and live
/// entirely in its `visual`, e.g. a writer-stored card or bar). Used by both the
/// visibility filter and [NodeVisualiser]'s own-row gate so such a node is never
/// dropped as "empty".
bool _nodeHasOwnContent(StoryNode n) {
  if (n.text.isNotEmpty || n.isImage) return true;
  switch (n.visualType) {
    case NodeVisualType.chipSet:
      return _chipItemsOf(n).isNotEmpty;
    case NodeVisualType.timelineEntry:
      return _timelineTitleOf(n).isNotEmpty;
    case NodeVisualType.barMeter:
    case NodeVisualType.gauge:
      return (n.visual?.params['value'] as num?) != null;
    case NodeVisualType.card:
      final p = n.visual?.params ?? const {};
      return ((p['title'] as Object?)?.toString().trim().isNotEmpty ?? false) ||
          ((p['body'] as Object?)?.toString().trim().isNotEmpty ?? false);
    case NodeVisualType.smallTable:
      return (n.visual?.params['rows'] as List?)?.isNotEmpty ?? false;
    default:
      return n.displayGist.isNotEmpty;
  }
}

bool _hasVisibleContentFor(StoryNode n, bool publicOnly) {
  final visible = publicOnly ? n.visibility == NodeVis.public : true;
  if (visible && _nodeHasOwnContent(n)) return true;
  return n.children.any((c) => _hasVisibleContentFor(c, publicOnly));
}

Future<void> _openNodeChat(
    BuildContext context, StoryNode target, _NvCfg cfg) async {
  if (target.isLink && target.linkUrl.isNotEmpty) {
    final uri = Uri.tryParse(target.linkUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return;
  }
  if (target.isImage && cfg.onImageTap != null) {
    cfg.onImageTap!(target);
    return;
  }
  await showNodeChat(
    context,
    node: target,
    surface: cfg.surface,
    api: cfg.api,
    isOwner: cfg.isOwner,
    onChanged: cfg.onChanged,
  );
}

/// A node's chip labels: its `params.items`, else its gist as one chip, else
/// empty (→ the dispatch falls back to the gist row).
List<String> _chipItemsOf(StoryNode n) {
  final raw = n.visual?.params['items'];
  if (raw is List) {
    final items =
        raw.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
    if (items.isNotEmpty) return items;
  }
  final g = n.displayGist.trim();
  return g.isEmpty ? const [] : [g];
}

String _timelineTitleOf(StoryNode n) {
  final t = (n.visual?.params['title'] as Object?)?.toString().trim() ?? '';
  return t.isNotEmpty ? t : n.displayGist.trim();
}

String _timelineDateOf(StoryNode n) =>
    (n.visual?.params['date'] as Object?)?.toString().trim() ?? '';

/// The pseudo aggregate-type for consecutive report image leaves → ONE
/// swipeable [NodePhotoCarousel]. Not a real [NodeVisualType]: it's a grouping
/// key internal to [_siblingWidgets].
const String _kImageAggType = '__photo_carousel_agg__';

// --- min/max range pairing (founder build 2502) ---------------------------
// A `<base>_min` + `<base>_max` pair is the TWO ENDS of ONE quantity's range,
// NOT two independent scale traits. The write-time backfill picks `bar_meter`
// for each end because each is numeric — WRONG for a two-ended range. At the
// section level the renderer detects the pair (by the field ids, with a
// Youngest/Oldest label fallback) and draws ONE combined range row
// ("Partner age preference 21–56") with NO bar for either end. A lone end (no
// partner present) renders as a PLAIN labelled row, also with no bar. This is
// RENDER only — the two stored nodes stay two nodes.

/// One parsed end of a `<base>_min`/`<base>_max` range.
class _RangeEnd {
  const _RangeEnd(this.base, {required this.isMax});

  /// The shared quantity key (`partner_age`, or `label:<quantity>` when matched
  /// only by a Youngest/Oldest label) — the two ends of one range share it.
  final String base;

  /// True for the MAX (oldest/highest) end, false for the MIN (youngest/lowest).
  final bool isMax;
}

final RegExp _rangeIdRe = RegExp(r'^(.+)_(min|max)$');
final RegExp _rangeLabelRe = RegExp(
    r'^(youngest|oldest|lowest|highest|minimum|maximum)\s+(.+)$');

/// Parse a node as one END of a min/max range, or null if it is not one.
/// The field id (`<base>_min` / `<base>_max`) is the strong signal; a
/// Youngest/Oldest-style label is the fallback for a node whose id lacks the
/// suffix. A genuine scale trait (`social_energy`, `cleanliness_index`, …) has
/// neither and is never treated as a range end — it keeps its bar.
_RangeEnd? _rangeEndOf(StoryNode n) {
  final idm = _rangeIdRe.firstMatch(n.id);
  if (idm != null) {
    return _RangeEnd(idm.group(1)!, isMax: idm.group(2) == 'max');
  }
  final lm = _rangeLabelRe.firstMatch(n.label.trim().toLowerCase());
  if (lm != null) {
    const maxWords = {'oldest', 'highest', 'maximum'};
    return _RangeEnd('label:${lm.group(2)!.trim()}',
        isMax: maxWords.contains(lm.group(1)));
  }
  return null;
}

/// The numeric value carried by a range-end node — its `bar_meter`/`gauge`
/// `params.value`, else its stat value, else a number parsed from its gist/text.
/// Null when no number is present.
double? _rangeEndValue(StoryNode n) {
  final v = n.visual?.params['value'];
  if (v is num) return v.toDouble();
  if (n.statValue != null) return n.statValue;
  return double.tryParse(n.displayGist.trim()) ?? double.tryParse(n.text.trim());
}

String _capitalizeFirst(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The combined row label for a `<base>` range. `partner_age` reads
/// "Partner age preference" (founder build 2502); any other base derives a
/// sensible label from the quantity shared by the two ends' labels, falling
/// back to the base id with underscores as spaces.
String _rangeCombinedLabel(String base, StoryNode lo, StoryNode hi) {
  if (base == 'partner_age') return 'Partner age preference';
  final loQ = _rangeLabelRe.firstMatch(lo.label.trim().toLowerCase())?.group(2);
  final hiQ = _rangeLabelRe.firstMatch(hi.label.trim().toLowerCase())?.group(2);
  if (loQ != null && hiQ != null && loQ.trim() == hiQ.trim()) {
    return _capitalizeFirst(loQ.trim());
  }
  if (base.startsWith('label:')) {
    return _capitalizeFirst(base.substring(6).trim());
  }
  return _capitalizeFirst(base.replaceAll('_', ' ').trim());
}

/// A labelled range/plain row: the visibility bullet + `<label>: <value>`,
/// inset like a sibling row and tapping through to [target]'s node chat. Used
/// for both the combined min–max row and a lone end (no bar in either case).
Widget _rangeRowWidget(
  BuildContext context,
  StoryNode target,
  String label,
  String value,
  _NvCfg cfg,
  double inset, {
  IconData? icon,
}) {
  final theme = Theme.of(context);
  // A fixed per-field icon (keyed on the range base) renders INSTEAD of the
  // visibility bullet, carrying the row's visibility colour — the same
  // treatment as a standard-field icon (founder build 2507). A `mixed` subtree
  // has no single colour, so it keeps the bullet.
  final showIcon = icon != null && target.subtreeVisibility != NodeVis.mixed;
  return Padding(
    padding: EdgeInsetsDirectional.only(start: inset),
    child: InkWell(
      key: Key('node_range_row_${target.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openNodeChat(context, target, cfg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Same fixed-width leading slot as [NodeVisualiser._row] so a
            // range/plain row's text lines up on the ONE profile text column.
            SizedBox(
              width: 18,
              child: Padding(
                padding: EdgeInsets.only(top: showIcon ? 2 : 6),
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: showIcon
                      ? Icon(icon,
                          key: Key('node_range_icon_${target.id}'),
                          size: 18,
                          color: nodeVisibilityColor(target.subtreeVisibility))
                      : NodeVisibilityBullet(
                          visibility: target.subtreeVisibility),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: theme.textTheme.bodyLarge,
                  children: [
                    TextSpan(
                      text: '$label: ',
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: value),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The aggregating palette type a LEAF node contributes to a sibling group, or
/// null if it can't be aggregated (not a chip/timeline/image leaf, or it has
/// children — those render recursively so their subtree is never dropped).
///
/// Image leaves aggregate ONLY on the report surface (the appearance / research
/// photo carousel, generalized): on Your Story / the public profile each image
/// stays an inline thumbnail, unchanged. A CANDIDATE (answer_type `candidate`,
/// with its is-me/not-me verdict) is NOT an image leaf and never sweeps in.
String? _aggType(StoryNode n, NodeVisualiserSurface surface) {
  if (n.children.isNotEmpty) return null;
  if (n.isImage && surface == NodeVisualiserSurface.report) {
    return _kImageAggType;
  }
  final t = n.visualType;
  if (t == NodeVisualType.chipSet && _chipItemsOf(n).isNotEmpty) return t;
  if (t == NodeVisualType.timelineEntry && _timelineTitleOf(n).isNotEmpty) {
    return t;
  }
  return null;
}

Widget _chipWidget(
    BuildContext context, String label, StoryNode target, int i, _NvCfg cfg) {
  final ac = context.ac;
  return InkWell(
    key: Key('node_chip_${target.id}_$i'),
    borderRadius: BorderRadius.circular(999),
    onTap: () => _openNodeChat(context, target, cfg),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ac.fgDim.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ac.fgDim.withValues(alpha: 0.25)),
      ),
      child: Text(label, style: AymaType.sans(size: 13)),
    ),
  );
}

Widget _timelineRowWidget(BuildContext context, StoryNode n, _NvCfg cfg,
    {required bool first}) {
  final ac = context.ac;
  final date = _timelineDateOf(n);
  return InkWell(
    key: Key('node_timeline_${n.id}'),
    borderRadius: BorderRadius.circular(8),
    onTap: () => _openNodeChat(context, n, cfg),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The rail: a dot with a connector line above it (joined for a group).
          SizedBox(
            width: 14,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: 6,
                  color: first
                      ? Colors.transparent
                      : ac.fgDim.withValues(alpha: 0.35),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: ac.fgDim, shape: BoxShape.circle),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (date.isNotEmpty)
                  Text(date, style: AymaType.mono(size: 11, color: ac.fgMute)),
                // The timeline entry's title/gist WRAPS in full — never chopped
                // mid-sentence (founder build 2495).
                Text(_timelineTitleOf(n),
                    style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Render a visibility-filtered sibling list: every image leaf aggregates
/// into ONE swipeable carousel at the first image's slot; consecutive
/// aggregatable leaves of one type (chip_set / timeline_entry) merge into one
/// visual; a `<base>_min`/`<base>_max` pair renders as one range row; every
/// other node renders recursively through [NodeVisualiser]. [indentStart]
/// insets the aggregate to match where a child row would sit.
List<Widget> _siblingWidgets(
  BuildContext context,
  List<StoryNode> visible,
  _NvCfg cfg, {
  required double indentStart,
  required int depth,
}) {
  // Detect `<base>_min`/`<base>_max` range pairs among these siblings BEFORE
  // grouping (founder build 2502). A base with BOTH ends renders as one
  // combined range row (no bar); a lone end renders as a plain row (no bar).
  final minByBase = <String, StoryNode>{};
  final maxByBase = <String, StoryNode>{};
  final endOf = <String, _RangeEnd>{};
  for (final n in visible) {
    final e = _rangeEndOf(n);
    if (e == null) continue;
    endOf[n.id] = e;
    (e.isMax ? maxByBase : minByBase).putIfAbsent(e.base, () => n);
  }
  final emittedRangeBases = <String>{};

  final surface = cfg.surface;

  // EVERY image leaf in this sibling list aggregates into ONE swipeable
  // carousel — NOT only a consecutive run (Scout NOTE 255: a report's photos
  // split into a 4-image carousel + three single "large embedded" images
  // because the appearance photos weren't adjacent to the web-research ones).
  // The carousel renders at the FIRST image's position; every later image leaf
  // is pulled into that same carousel instead of rendering on its own.
  final imageGroup = <StoryNode>[
    for (final n in visible)
      if (_aggType(n, surface) == _kImageAggType) n,
  ];

  // Partition the remaining (non-image) nodes into consecutive same-type
  // aggregatable runs vs singletons, inserting ONE empty marker group where the
  // carousel belongs (the first image's slot).
  final groups = <List<StoryNode>>[];
  var carouselMarked = false;
  for (final n in visible) {
    if (_aggType(n, surface) == _kImageAggType) {
      if (!carouselMarked) {
        groups.add(const <StoryNode>[]); // carousel marker (rendered once)
        carouselMarked = true;
      }
      continue;
    }
    final t = _aggType(n, surface);
    if (t != null &&
        groups.isNotEmpty &&
        groups.last.isNotEmpty &&
        _aggType(groups.last.first, surface) == t) {
      groups.last.add(n);
    } else {
      groups.add([n]);
    }
  }

  final out = <Widget>[];
  // The inset a NON-aggregated sibling row sits at — matches NodeVisualiser's
  // own-row indent for this depth, so the combined/plain range row lines up.
  final rowInset = depth.clamp(0, NodeVisualiser._maxIndentSteps) *
      NodeVisualiser._indentStep;
  for (final group in groups) {
    if (group.isEmpty) {
      // The carousel marker: ALL of this sibling list's image leaves → ONE
      // swipeable carousel (every report's photos, the appearance look
      // generalized). A single image still renders as one tile.
      out.add(Padding(
        padding: EdgeInsetsDirectional.only(
            start: indentStart, top: 8, bottom: 8),
        child: NodePhotoCarousel(images: imageGroup),
      ));
      continue;
    }
    // A single range end: combine with its partner (one row) or render plain.
    if (group.length == 1 && endOf.containsKey(group.first.id)) {
      final end = endOf[group.first.id]!;
      final lo = minByBase[end.base];
      final hi = maxByBase[end.base];
      if (lo != null && hi != null) {
        // Paired → ONE combined range row, emitted at the first end reached.
        if (emittedRangeBases.add(end.base)) {
          final loV = _rangeEndValue(lo);
          final hiV = _rangeEndValue(hi);
          final value = (loV != null && hiV != null)
              ? '${NodeVisualiser._trimNum(loV)}–${NodeVisualiser._trimNum(hiV)}'
              : (loV ?? hiV) != null
                  ? NodeVisualiser._trimNum((loV ?? hiV)!)
                  : '';
          out.add(_rangeRowWidget(context, lo,
              _rangeCombinedLabel(end.base, lo, hi), value, cfg, rowInset,
              icon: NodeVisualiser._rangePairIcons[end.base]));
        }
        continue;
      }
      // Lone end → plain labelled row, NO bar.
      final v = _rangeEndValue(group.first);
      out.add(_rangeRowWidget(
        context,
        group.first,
        group.first.label.isNotEmpty ? group.first.label : group.first.displayGist,
        v != null ? NodeVisualiser._trimNum(v) : group.first.displayGist,
        cfg,
        rowInset,
        icon: NodeVisualiser._rangePairIcons[end.base],
      ));
      continue;
    }
    final t = _aggType(group.first, surface);
    if (group.length > 1 && t != null) {
      final body = t == NodeVisualType.chipSet
          ? Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in group)
                  for (var i = 0; i < _chipItemsOf(n).length; i++)
                    _chipWidget(context, _chipItemsOf(n)[i], n, i, cfg),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < group.length; i++)
                  _timelineRowWidget(context, group[i], cfg, first: i == 0),
              ],
            );
      out.add(Padding(
        padding: EdgeInsetsDirectional.only(
            start: indentStart, top: 4, bottom: 4),
        child: body,
      ));
    } else {
      out.add(NodeVisualiser(
        node: group.first,
        surface: cfg.surface,
        onChanged: cfg.onChanged,
        api: cfg.api,
        isOwner: cfg.isOwner,
        onImageTap: cfg.onImageTap,
        onCandidateVerdict: cfg.onCandidateVerdict,
        depth: depth,
      ));
    }
  }
  return out;
}


/// The ONE renderer for a person-graph IMAGE node's photo (2o — no parallel
/// The first http(s) source URL carried by an image node — its origin page
/// ([StoryNode.sourceRef]), an explicit link, or a URL-shaped caption. Used by
/// [nodeImageSourceFallback] to offer a "View source" chip instead of a dead
/// tile when a web-research photo can't be loaded.
String? _nodeImageSourceUrl(StoryNode node) {
  for (final candidate in [node.sourceRef, node.linkUrl, node.imageRead]) {
    final u = candidate.trim();
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
  }
  return null;
}

/// The clean fallback painted when a web-research photo tile can't decode — a
/// host that blocks hotlinking / 403s a client, a URL that isn't really an
/// image, or any load failure (Leg 33). NEVER the broken-image glyph: a neutral
/// tile, and — when the node knows where the photo came from — a tappable
/// "View source" chip so an unhotlinkable but real source is still reachable.
Widget nodeImageSourceFallback(BuildContext context, StoryNode node) {
  final scheme = Theme.of(context).colorScheme;
  final src = _nodeImageSourceUrl(node);
  final Widget inner = src == null
      ? Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_outlined, size: 22, color: scheme.outline),
            const SizedBox(height: 4),
            Text('No preview',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
          ],
        )
      : Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.public, size: 22, color: scheme.onSurfaceVariant),
            const SizedBox(height: 4),
            Text('View source',
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                    decoration: TextDecoration.underline)),
          ],
        );
  final tile = Container(
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(8),
    child: inner,
  );
  if (src == null) return tile;
  return InkWell(
    key: Key('node_image_source_link_${node.id}'),
    onTap: () async {
      final uri = Uri.tryParse(src);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    },
    child: tile,
  );
}

/// image renderers). The inline [NodeVisualiser] uses it bounded (a 240px
/// square with Ayma's read caption below, tap handled by the enclosing node
/// row); the profile photo carousel (2o P4) uses it [fill] — a full-bleed
/// cover page, no caption, tap routed to the carousel's own fullscreen viewer.
/// One widget renders the image in both places, so a photo never has a second
/// bespoke renderer to drift from.
class NodeImage extends StatelessWidget {
  const NodeImage({
    super.key,
    required this.node,
    this.fill = false,
    this.onTap,
    this.error,
    this.displayWidth = 480.0,
  });

  /// The image node to render ([StoryNode.isImage] is expected true).
  final StoryNode node;

  /// Full-bleed cover (the carousel hero page) instead of the bounded 240px
  /// inline image with Ayma's read caption below it.
  final bool fill;

  /// What tapping the image does. Null leaves taps to an enclosing handler
  /// (the inline node row). The carousel passes its own fullscreen viewer.
  final VoidCallback? onTap;

  /// Fallback painted when the photo cannot decode (the carousel passes its
  /// seed gradient).
  final Widget? error;

  final double displayWidth;

  @override
  Widget build(BuildContext context) {
    // A failed photo NEVER shows the broken-image glyph: fall back to a clean
    // neutral tile / "View source" chip (Leg 33). A caller-supplied [error]
    // (the carousel's seed gradient) still wins when given.
    final fallback = error ?? nodeImageSourceFallback(context, node);
    if (fill) {
      final photo = AymaPhoto(
        key: Key('node_image_${node.id}'),
        url: node.imageUrl,
        displayWidth: displayWidth,
        error: fallback,
      );
      return onTap == null
          ? photo
          : GestureDetector(onTap: onTap, child: photo);
    }
    final bounded = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 1,
          child: AymaPhoto(
            key: Key('node_image_${node.id}'),
            url: node.imageUrl,
            displayWidth: displayWidth,
            error: fallback,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        onTap == null
            ? bounded
            : GestureDetector(onTap: onTap, child: bounded),
        if (node.imageRead.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              node.imageRead,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
