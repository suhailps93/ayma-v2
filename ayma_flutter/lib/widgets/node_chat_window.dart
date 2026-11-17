/// Tapping any person-graph node opens the REAL partial Ayma chat window for it.
///
/// There is no intermediate card: a node tap goes straight to the half-screen
/// docked chat ([showNodeChat]) with the node attached as the persistent context
/// card above the composer (text, or for an image node the image + its read +
/// is-you verdict). The owner actions live INSIDE that chat as quick-action
/// BUBBLES ([NodeActionBubbles]) pinned above the composer — not as per-bullet
/// icon buttons, and never a separate "Chat about it" step (founder Nov 17):
///
///  - Make public / Make private — the visibility toggle WITH the cascade.
///  - Edit manually — edit this node's text.
///  - Add a line — add a child detail under this node.
///  - Delete — with the settled confirmation (names how many children go too).
///
/// Owner-only bubbles appear only on the owner's own EDITABLE nodes on an
/// editing surface (Story / a report / the graph detail); on another person's
/// public profile, on a non-editable report node, or on the owner's public
/// profile the same tap opens the chat with the context card and composer only,
/// with no edit bubbles (read-only Q&A).
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import 'ask_ayma_overlay.dart';

/// Whether [node] exposes the owner edit bubbles on [surface] for the current
/// viewer. The edit bubbles need an editable node, an owner viewer, and an
/// editing surface — the owner's own public profile and non-editable report
/// nodes stay read-only (founder: never present an edit affordance that can't
/// or shouldn't act).
bool nodeHasOwnerActions(
  StoryNode node,
  NodeVisualiserSurface surface,
  bool isOwner,
) =>
    isOwner &&
    node.editable &&
    (surface == NodeVisualiserSurface.story ||
        surface == NodeVisualiserSurface.report ||
        surface == NodeVisualiserSurface.graphDetail);

/// Open the REAL partial Ayma chat window for [node] — the half-screen docked
/// sheet hosting the one shared ChatScreen, with the node attached as the
/// persistent context card above the composer (text, or for an image node the
/// image + its read + is-you verdict). Ayma gets the whole node + what's
/// connected to it as context on every message, resolved server-side through
/// the single graph lookup (`graph_node_id`). This is what tapping ANY node
/// does, on every surface (founder Nov 17). Turns save to the one main
/// conversation.
///
/// When the viewer owns an editable node on an editing surface
/// ([nodeHasOwnerActions]), the owner action bubbles ([NodeActionBubbles]) ride
/// inside the chat, pinned above the composer; [onChanged] fires after each
/// bubble mutation so the host can refetch its tree.
Future<void> showNodeChat(
  BuildContext context, {
  required StoryNode node,
  ApiClient? api,
  NodeVisualiserSurface surface = NodeVisualiserSurface.story,
  bool isOwner = true,
  VoidCallback? onChanged,
}) {
  final client = api ?? ApiClient();
  final isImage = node.isImage;
  final text = node.text.isNotEmpty ? node.text : node.label;
  return showAskAymaOverlay(
    context,
    api: client,
    ctx: AskAymaContext(
      origin: AskAymaOrigin.graphNode,
      nodeId: node.id,
      quoteTitle: isImage ? 'Photo' : (node.label.isNotEmpty ? node.label : 'This'),
      quoteText: isImage ? node.imageRead : text,
      nodeImageUrl: isImage ? node.imageUrl : '',
      nodeImageRead: isImage ? node.imageRead : '',
      nodeIsYou: isImage ? node.isYou : '',
    ),
    scopedActions: nodeHasOwnerActions(node, surface, isOwner)
        ? NodeActionBubbles(node: node, api: client, onChanged: onChanged)
        : null,
  );
}

/// The owner action bubbles pinned inside the partial node chat, above the
/// composer: Make public/private (with the cascade), Edit manually, Add a line,
/// and Delete (with the children-count confirmation). Each bubble is wired to
/// the real `person_graph` mutation end-to-end; [onChanged] fires after every
/// successful change so the host can refetch its tree, and Delete also closes
/// the chat since the node is gone. Shown only when [nodeHasOwnerActions] is
/// true for the opening node/surface/owner — otherwise [showNodeChat] passes
/// none and the chat is read-only Q&A.
class NodeActionBubbles extends StatefulWidget {
  const NodeActionBubbles({
    super.key,
    required this.node,
    required this.api,
    this.onChanged,
  });

  final StoryNode node;
  final ApiClient api;
  final VoidCallback? onChanged;

  @override
  State<NodeActionBubbles> createState() => _NodeActionBubblesState();
}

class _NodeActionBubblesState extends State<NodeActionBubbles> {
  bool _busy = false;
  String? _error;
  late String _visibility = widget.node.visibility;

  /// Runs [action], surfacing a one-line error on failure. Returns true when it
  /// succeeded (so the caller can fire [onChanged] / close the sheet).
  Future<bool> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    var ok = false;
    try {
      await action();
      ok = true;
    } catch (_) {
      if (mounted) setState(() => _error = 'That did not go through. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return ok;
  }

  Future<void> _toggleVisibility() async {
    final next = _visibility == NodeVis.public ? NodeVis.private : NodeVis.public;
    final ok = await _run(
      () => widget.api.graphNodeSetVisibility(widget.node.id, next),
    );
    if (ok) {
      if (mounted) setState(() => _visibility = next);
      widget.onChanged?.call();
    }
  }

  Future<void> _editManually() async {
    final controller = TextEditingController(
      text: widget.node.text.isNotEmpty ? widget.node.text : widget.node.label,
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(hintText: 'Your words'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    final ok = await _run(() => widget.api.graphSetNodeText(widget.node.id, result));
    if (ok) widget.onChanged?.call();
  }

  Future<void> _addChild() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a line'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(hintText: 'A detail under this'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    final ok = await _run(() async {
      await widget.api.graphAddChild(
        widget.node.id,
        result,
        visibility:
            _visibility == NodeVis.public ? NodeVis.public : NodeVis.private,
      );
    });
    if (ok) widget.onChanged?.call();
  }

  Future<void> _delete() async {
    int count = 0;
    try {
      count = await widget.api.graphDeleteCount(widget.node.id);
    } catch (_) {
      // fall back to a plain confirmation if the count can't be fetched
    }
    if (!mounted) return;
    final msg = count > 0
        ? 'Delete this and the $count ${count == 1 ? 'line' : 'lines'} under it?'
        : 'Delete this?';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _run(() => widget.api.graphDeleteNode(widget.node.id));
    if (done) {
      widget.onChanged?.call();
      // The node is gone — close the chat window it was the subject of.
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Bubble(
              key: const Key('bubble_visibility'),
              icon: _visibility == NodeVis.public
                  ? Icons.lock_outline
                  : Icons.public,
              label: _visibility == NodeVis.public ? 'Make private' : 'Make public',
              onTap: _busy ? null : _toggleVisibility,
            ),
            _Bubble(
              key: const Key('bubble_edit_manually'),
              icon: Icons.edit_outlined,
              label: 'Edit manually',
              onTap: _busy ? null : _editManually,
            ),
            _Bubble(
              key: const Key('bubble_add_child'),
              icon: Icons.add,
              label: 'Add a line',
              onTap: _busy ? null : _addChild,
            ),
            _Bubble(
              key: const Key('bubble_delete'),
              icon: Icons.delete_outline,
              label: 'Delete',
              destructive: true,
              onTap: _busy ? null : _delete,
            ),
          ],
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = destructive ? scheme.error : scheme.onSurface;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
