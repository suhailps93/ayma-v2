/// The ONE reusable renderer for a person-graph node and all its children.
///
/// One data model, one renderer: Your Story, the public profile, every report,
/// the image carousel and the person-graph tap-detail all render through this
/// widget. INPUT is a single [StoryNode]; it renders that node's content and
/// all of its child nodes recursively (children indented by level). This
/// removes the parallel-renderer defect class structurally (founder Nov 16/17).
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

import '../models/story_node.dart';
import '../services/api_client.dart';
import 'ayma_photo.dart';
import 'node_chat_window.dart';
import 'node_visibility.dart';

class NodeVisualiser extends StatelessWidget {
  const NodeVisualiser({
    super.key,
    required this.node,
    required this.surface,
    this.onChanged,
    this.api,
    this.isOwner = true,
    this.onChatToEdit,
    this.onImageTap,
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

  /// Host hook for the "Chat to edit" bubble — opens the shared chat overlay
  /// scoped to [node]. When null the bubble closes the window without chat.
  final void Function(StoryNode node)? onChatToEdit;

  /// Overrides what tapping an image node does (the carousel passes its own
  /// viewer); defaults to opening the node chat window.
  final void Function(StoryNode node)? onImageTap;

  /// Recursion depth — drives the per-level indentation. Hosts leave it 0.
  final int depth;

  bool get _publicOnly => surface == NodeVisualiserSurface.publicProfile;

  bool _visible(String vis) => _publicOnly ? vis == NodeVis.public : true;

  bool _hasVisibleContent(StoryNode n) {
    if (_visible(n.visibility) && (n.text.isNotEmpty || n.isImage)) return true;
    return n.children.any(_hasVisibleContent);
  }

  Future<void> _openChat(BuildContext context) async {
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
      onChatToEdit: onChatToEdit,
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
        for (final child in visibleChildren)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 4),
            child: NodeVisualiser(
              node: child,
              surface: surface,
              onChanged: onChanged,
              api: api,
              isOwner: isOwner,
              onChatToEdit: onChatToEdit,
              onImageTap: onImageTap,
              depth: depth + 1,
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context) {
    return InkWell(
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
    );
  }

  Widget _content(BuildContext context) {
    if (node.isImage) return _imageContent(context);
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

  Widget _imageContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 1,
              child: AymaPhoto(
                key: Key('node_image_${node.id}'),
                url: node.imageUrl,
                displayWidth: 480,
              ),
            ),
          ),
        ),
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
    this.onChatToEdit,
    this.onImageTap,
  });

  final GraphTreeSection section;
  final NodeVisualiserSurface surface;
  final VoidCallback? onChanged;
  final ApiClient? api;
  final bool isOwner;
  final void Function(StoryNode node)? onChatToEdit;
  final void Function(StoryNode node)? onImageTap;

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
            onChatToEdit: onChatToEdit,
            onImageTap: onImageTap,
          ),
      ],
    );
  }
}
