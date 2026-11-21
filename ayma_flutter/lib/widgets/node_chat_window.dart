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
/// viewer. The edit bubbles need an editable node and an owner viewer. On the
/// owner's OWN public profile the bubbles now appear too (founder Nov 20:
/// "when I click on public items it should have the bubble to make private or
/// delete") — tapping a public item offers Make private + Delete right there,
/// and the change leaves the public render immediately. Someone else's public
/// profile (`isOwner` false) and non-editable report nodes stay read-only.
bool nodeHasOwnerActions(
  StoryNode node,
  NodeVisualiserSurface surface,
  bool isOwner,
) =>
    isOwner &&
    node.editable &&
    (surface == NodeVisualiserSurface.story ||
        surface == NodeVisualiserSurface.report ||
        surface == NodeVisualiserSurface.graphDetail ||
        surface == NodeVisualiserSurface.publicProfile);

/// The label [node]'s rendered row prefixes before its value — the single text
/// that [stripNodeOwnLabel] must recognise — or `''` when the node renders no
/// label prefix.
///
/// Two node shapes render a "`<label>: <value>`" row and so can double:
///  - a STANDARD field (Name, Age, Location, …): the client prepends its
///    [StoryNode.standardLabel] at render (see [NodeVisualiser]), the stored
///    value is bare;
///  - a non-standard QUESTIONNAIRE-FIELD node (an enum/bool/number/scale answer,
///    e.g. Career "Role of work in life"): the server bakes "`<prompt>: <value>`"
///    into the node text (`person_graph_render._answer_text`), and that prompt
///    arrives as [StoryNode.label].
///
/// For both, the label to strip is that rendered prefix. Truly label-less nodes
/// — emergent/narrative facts, child bullets ([StoryNode.label] is empty) — return
/// `''` and are left untouched.
String nodeOwnLabel(StoryNode node) {
  if (node.standard) return (node.standardLabel ?? '').trim();
  return node.label.trim();
}

/// [value] with any leading copy of [node]'s own rendered label ([nodeOwnLabel])
/// stripped.
///
/// A labelled node renders as "`<label>: <value>`" but its STORED value is the
/// bare value alone. If a value itself begins with "`<label>:`" — existing
/// doubled data, or a paste of the rendered row — the next render would prepend
/// the label again, doubling it, and every re-edit would add another copy. This
/// strips every leading own-label prefix so the stored value stays the bare
/// value. A node with no rendered label prefix is returned unchanged. Idempotent:
/// a value with no own-label prefix is returned as-is.
String stripNodeOwnLabel(String value, StoryNode node) {
  final label = nodeOwnLabel(node);
  if (label.isEmpty) return value;
  final lower = label.toLowerCase();
  var v = value.trimLeft();
  while (v.toLowerCase().startsWith('$lower:')) {
    v = v.substring(label.length + 1).trimLeft();
  }
  return v;
}

/// The bare, editable value of [node] for the "Edit manually" field — never the
/// rendered "label: value". Uses the node's value ([StoryNode.text]); for a
/// standard node with no value it is empty (the label is never put in as the
/// value), and a non-standard node falls back to its prompt ([StoryNode.label]).
/// Any leading own-label is stripped (defensive against already-doubled data and
/// against the server-baked "`<prompt>: <value>`" of a questionnaire-field node).
String editableNodeValue(StoryNode node) {
  final raw =
      node.text.isNotEmpty ? node.text : (node.standard ? '' : node.label);
  return stripNodeOwnLabel(raw, node);
}

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
      text: editableNodeValue(widget.node),
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
    if (result == null) return;
    // Guard against label-doubling: a value entered (or pasted) as its own
    // "label: value" render is stored as the bare value; the label is re-applied
    // at render time, never baked into the value.
    final cleaned = stripNodeOwnLabel(result, widget.node);
    if (cleaned.isEmpty) return;
    final ok = await _run(() => widget.api.graphSetNodeText(widget.node.id, cleaned));
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
    // Deleting an IMAGE node RETAINS an Ayma-only copy (founder retention rule);
    // every other node kind hard-deletes with its subtree. The confirmation copy
    // must be truthful to that (Scout NOTE 256) — never "removes it everywhere"
    // for a photo that Ayma keeps.
    final isImage = widget.node.isImage;
    int count = 0;
    if (!isImage) {
      try {
        count = await widget.api.graphDeleteCount(widget.node.id);
      } catch (_) {
        // fall back to a plain confirmation if the count can't be fetched
      }
    }
    if (!mounted) return;
    final msg = isImage
        ? 'This removes it from your story and profile. Ayma keeps its own '
            'copy in your Photos.'
        : (count > 0
            ? 'Delete this and the $count ${count == 1 ? 'line' : 'lines'} under it?'
            : 'Delete this?');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isImage ? 'Remove this photo?' : 'Delete'),
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
            child: Text(isImage ? 'Remove' : 'Delete'),
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
