/// The ONE reusable renderer for a person-graph node and all its children.
///
/// One data model, one renderer: Your Story, the public profile, every report,
/// the image carousel and the person-graph tap-detail all render through this
/// widget. INPUT is a single [StoryNode]; it renders that node's content and
/// all of its child nodes recursively — each row indented by its ACTUAL level
/// in the tree (a level-2 node one step in from a level-1 one, level-3 one step
/// further), so a conversational fact nests visibly under the standard block
/// even when it is stored as a parentless section root. This removes the
/// parallel-renderer defect class structurally (founder Nov 16/17).
///
/// Rules folded in:
///  - FIXED ORDER + STANDARD fields: the backend tree already orders standard
///    (known structured) children first; a standard node renders as a labelled
///    field ("Name: …") rather than raw bullet text.
///  - IMAGE nodes render inline under their parent; tapping one opens its node
///    context (read + is-you verdict + source) in the node chat window.
///  - VISIBILITY colours: every bullet is coloured by its (subtree) visibility
///    — green public, yellow private, AI-only third, split for a mixed subtree.
///  - VISIBILITY FILTER: the public-profile surface renders public nodes only;
///    every other (owner) surface renders what the tree carries.
///  - TAP-TO-CHAT: tapping a node opens the partial docked chat window with the
///    node as context; the owner action bubbles live there. The bullets stay
///    clean — no per-bullet icon buttons.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../theme.dart';
import 'ayma_photo.dart';
import 'node_chat_window.dart';
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

  /// Render depth — the floor for this node's indentation, so a child always
  /// sits at least one step deeper than its parent even if a stored [level] is
  /// stale. Hosts (a section list) leave it 0.
  final int depth;

  /// One indent step, in dp, per tree level.
  static const double _indentStep = 18;

  /// The deepest level that still earns a fresh indent step. Past this, every
  /// level shares the same inset and the content text wraps instead, so deep
  /// nesting can't push a row off-screen at phone width / large text scale.
  static const int _maxIndentSteps = 5;

  /// Indent steps for this node: its ACTUAL level in the tree (a level-2 node
  /// sits one step in from a level-1 one), but never fewer than [depth] so a
  /// nested child is always one step deeper than its parent. Capped at
  /// [_maxIndentSteps]. This is what makes a parentless level-2 fact (the Your
  /// Story editor / content writers mint these) indent even though it renders
  /// as a flat section root — recursion depth alone would leave it flush.
  int get _indentSteps {
    final byLevel = node.level - 1;
    final steps = byLevel > depth ? byLevel : depth;
    if (steps < 0) return 0;
    return steps > _maxIndentSteps ? _maxIndentSteps : steps;
  }

  bool get _publicOnly => surface == NodeVisualiserSurface.publicProfile;

  bool _visible(String vis) => _publicOnly ? vis == NodeVis.public : true;

  bool _hasVisibleContent(StoryNode n) {
    if (_visible(n.visibility) && (n.text.isNotEmpty || n.isImage)) return true;
    return n.children.any(_hasVisibleContent);
  }

  Future<void> _openChat(BuildContext context) async {
    if (node.isLink && node.linkUrl.isNotEmpty) {
      final uri = Uri.tryParse(node.linkUrl);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    if (node.isImage && onImageTap != null) {
      onImageTap!(node);
      return;
    }
    final changed = await showNodeChatWindow(
      context,
      node: node,
      surface: surface,
      api: api,
      isOwner: isOwner,
    );
    if (changed) onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final showOwnRow =
        _visible(node.visibility) && (node.text.isNotEmpty || node.isImage);
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
        // Children are NOT wrapped in an indent here: each node indents itself
        // by its own level (see [_row]/[_indentSteps]), so a parentless level-2
        // fact indents the same as a genuinely nested one.
        for (final child in visibleChildren)
          NodeVisualiser(
            node: child,
            surface: surface,
            onChanged: onChanged,
            api: api,
            isOwner: isOwner,
            onImageTap: onImageTap,
            onCandidateVerdict: onCandidateVerdict,
            depth: depth + 1,
          ),
      ],
    );
  }

  Widget _row(BuildContext context) {
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
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: NodeVisibilityBullet(visibility: node.subtreeVisibility),
              ),
              const SizedBox(width: 10),
              Expanded(child: _content(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (node.isCandidate) return _candidateContent(context);
    if (node.isImage) return _imageContent(context);
    if (node.isStat) return _statContent(context);
    if (node.isLink) return _linkContent(context);
    final theme = Theme.of(context);
    if (node.standard && (node.standardLabel ?? '').isNotEmpty) {
      return RichText(
        text: TextSpan(
          style: theme.textTheme.bodyLarge,
          children: [
            TextSpan(
              text: '${node.standardLabel}: ',
              style: theme.textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: node.text),
          ],
        ),
      );
    }
    return Text(
      node.text.isNotEmpty ? node.text : node.label,
      style: theme.textTheme.bodyLarge,
    );
  }

  Widget _imageContent(BuildContext context) => NodeImage(node: node);

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
          crossAxisAlignment: CrossAxisAlignment.baseline,
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
              _bandPill(context, node.statText),
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
            child: Row(
              children: [
                FilledButton.tonal(
                  key: Key('node_candidate_me_${node.id}'),
                  onPressed: () => onCandidateVerdict!(node, true),
                  child: const Text('This is me'),
                ),
                const SizedBox(width: 8),
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
  });

  final GraphTreeSection section;
  final NodeVisualiserSurface surface;
  final VoidCallback? onChanged;
  final ApiClient? api;
  final bool isOwner;
  final void Function(StoryNode node)? onImageTap;
  final void Function(StoryNode node, bool isMe)? onCandidateVerdict;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            section.title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        for (final node in section.nodes)
          NodeVisualiser(
            node: node,
            surface: surface,
            onChanged: onChanged,
            api: api,
            isOwner: isOwner,
            onImageTap: onImageTap,
            onCandidateVerdict: onCandidateVerdict,
          ),
      ],
    );
  }
}

/// The ONE renderer for a person-graph IMAGE node's photo (2o — no parallel
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
    if (fill) {
      final photo = AymaPhoto(
        key: Key('node_image_${node.id}'),
        url: node.imageUrl,
        displayWidth: displayWidth,
        error: error,
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
            error: error,
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
