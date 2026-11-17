/// The partial docked chat window for one person-graph node.
///
/// Tapping any node the [NodeVisualiser] renders opens this half-screen docked
/// sheet with the node as the chat's context (shown as the context card above
/// the composer). The owner actions live INSIDE this window as quick-action
/// BUBBLES — not as per-bullet icon buttons — and every bubble is wired to the
/// real action end-to-end (founder Nov 17):
///
///  - Make public / Make private — the visibility toggle WITH the cascade.
///  - Edit manually — edit this node's text.
///  - Chat to edit — edit the node conversationally with Ayma (host callback).
///  - Delete — with the settled confirmation (names how many children go too).
///
/// Owner-only bubbles appear only on the owner's own nodes; on another person's
/// public profile the same tap opens the context card without them.
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import 'ask_ayma_overlay.dart';
import 'ayma_photo.dart';
import 'node_visibility.dart';

/// Open the REAL partial Ayma chat window for [node] — the half-screen docked
/// sheet hosting the one shared ChatScreen, with the node attached as the
/// persistent context card above the composer (text, or for an image node the
/// image + its read + is-you verdict). Ayma gets the whole node + what's
/// connected to it as context on every message, resolved server-side through
/// the single graph lookup (`graph_node_id`). This is "Chat about it" on any
/// node, on every surface (founder Nov 17). Turns save to the one main
/// conversation.
Future<void> showNodeChat(
  BuildContext context, {
  required StoryNode node,
  ApiClient? api,
}) {
  final isImage = node.isImage;
  final text = node.text.isNotEmpty ? node.text : node.label;
  return showAskAymaOverlay(
    context,
    api: api ?? ApiClient(),
    ctx: AskAymaContext(
      origin: AskAymaOrigin.graphNode,
      nodeId: node.id,
      quoteTitle: isImage ? 'Photo' : (node.label.isNotEmpty ? node.label : 'This'),
      quoteText: isImage ? node.imageRead : text,
      nodeImageUrl: isImage ? node.imageUrl : '',
      nodeImageRead: isImage ? node.imageRead : '',
      nodeIsYou: isImage ? node.isYou : '',
    ),
  );
}

/// Open the node ACTION sheet for [node] (the owner bubbles — make public/
/// private, edit, add a line, delete, and "Chat about it" which opens the real
/// partial chat window). Returns true when the node changed, so the caller can
/// refresh.
Future<bool> showNodeChatWindow(
  BuildContext context, {
  required StoryNode node,
  required NodeVisualiserSurface surface,
  ApiClient? api,
  bool isOwner = true,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _NodeChatSheet(
      node: node,
      surface: surface,
      api: api ?? ApiClient(),
      isOwner: isOwner,
    ),
  );
  return changed ?? false;
}

class _NodeChatSheet extends StatefulWidget {
  const _NodeChatSheet({
    required this.node,
    required this.surface,
    required this.api,
    required this.isOwner,
  });

  final StoryNode node;
  final NodeVisualiserSurface surface;
  final ApiClient api;
  final bool isOwner;

  @override
  State<_NodeChatSheet> createState() => _NodeChatSheetState();
}

class _NodeChatSheetState extends State<_NodeChatSheet> {
  bool _busy = false;
  bool _changed = false;
  String? _error;

  // The EDIT bubbles (visibility / edit / add / delete) need an editable node
  // on an owner-editing surface.
  bool get _ownerActions =>
      widget.isOwner &&
      widget.node.editable &&
      (widget.surface == NodeVisualiserSurface.story ||
          widget.surface == NodeVisualiserSurface.report ||
          widget.surface == NodeVisualiserSurface.graphDetail);

  // "Chat about it" is available on EVERY owner surface — including the owner's
  // public profile and non-editable report nodes — not just editable ones
  // (founder: every node gets a working Chat about it).
  bool get _canChat =>
      widget.isOwner &&
      (widget.surface == NodeVisualiserSurface.story ||
          widget.surface == NodeVisualiserSurface.report ||
          widget.surface == NodeVisualiserSurface.graphDetail ||
          widget.surface == NodeVisualiserSurface.publicProfile);

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      _changed = true;
    } catch (e) {
      if (mounted) setState(() => _error = 'That did not go through. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleVisibility() async {
    final next =
        widget.node.visibility == NodeVis.public ? NodeVis.private : NodeVis.public;
    await _run(() => widget.api.graphNodeSetVisibility(widget.node.id, next));
    if (mounted && _changed) Navigator.of(context).pop(true);
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
    await _run(() => widget.api.graphSetNodeText(widget.node.id, result));
    if (mounted && _changed) Navigator.of(context).pop(true);
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
    await _run(() async {
      await widget.api.graphAddChild(
        widget.node.id,
        result,
        visibility: widget.node.visibility == NodeVis.public
            ? NodeVis.public
            : NodeVis.private,
      );
    });
    if (mounted && _changed) Navigator.of(context).pop(true);
  }

  // "Chat about it" — close this action sheet and open the REAL partial Ayma
  // chat window with the node attached (never a dead no-op: this is the fix for
  // the old host-hook loop that only person_graph_screen wired).
  Future<void> _chatAbout() async {
    Navigator.of(context).pop(_changed);
    await showNodeChat(context, node: widget.node, api: widget.api);
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
    await _run(() => widget.api.graphDeleteNode(widget.node.id));
    if (mounted && _changed) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.6;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 16 + media.viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              _ContextCard(node: node),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (_canChat || _ownerActions)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // "Chat about it" is first and shows on every owner surface
                    // (even non-editable report nodes), opening the real partial
                    // chat window — never a dead no-op.
                    if (_canChat)
                      _Bubble(
                        key: const Key('bubble_chat_about'),
                        icon: Icons.chat_bubble_outline,
                        label: 'Chat about it',
                        onTap: _busy ? null : _chatAbout,
                      ),
                    if (_ownerActions) ...[
                      _Bubble(
                        key: const Key('bubble_visibility'),
                        icon: node.visibility == NodeVis.public
                            ? Icons.lock_outline
                            : Icons.public,
                        label: node.visibility == NodeVis.public
                            ? 'Make private'
                            : 'Make public',
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
                  ],
                )
              else
                Text(
                  'Ask Ayma about this',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The context card above the composer — the node as the chat's subject.
class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.node});

  final StoryNode node;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // An image node's own visibility (not the subtree's) is what the
          // Make public/private bubble flips, so the dot must read the node
          // itself, never the parent fact's colour (NOTE 250 item 4).
          NodeVisibilityBullet(
              visibility:
                  node.isImage ? node.visibility : node.subtreeVisibility,
              size: 14),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (node.isImage) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AspectRatio(
                      aspectRatio: 1.4,
                      child: AymaPhoto(url: node.imageUrl, displayWidth: 600),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (node.imageRead.isNotEmpty)
                    Text(node.imageRead,
                        style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    _isYouLine(node.isYou, node.imageRead) +
                        (node.sourceKind.isNotEmpty
                            ? '  •  from ${_sourceLabel(node.sourceKind)}'
                            : ''),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else ...[
                  if (node.standard && (node.standardLabel ?? '').isNotEmpty)
                    Text(
                      node.standardLabel!,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  Text(
                    node.text.isNotEmpty ? node.text : node.label,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // is_you unknown WITH a real read means Ayma looked and couldn't confirm
  // identity — never imply she hasn't checked when a read exists (NOTE 250 §4).
  static String _isYouLine(String isYou, String imageRead) => switch (isYou) {
        'yes' => 'This looks like you',
        'no' => 'This does not look like you',
        _ => imageRead.trim().isNotEmpty
            ? "Ayma read this but couldn't confirm it's you"
            : "Ayma hasn't checked whether this is you",
      };

  static String _sourceLabel(String kind) => switch (kind) {
        'chat' => 'a chat',
        'appearance_report' => 'your appearance report',
        'profile_grid' => 'your photos',
        'web' => 'the web',
        _ => kind,
      };
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
