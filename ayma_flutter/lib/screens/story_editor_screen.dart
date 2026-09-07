import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/text_diff.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/markdown_text.dart';

/// Your Story — one scrolling document over the user's wiki sections, with
/// version history, diffs, revert, and a highlight-to-chat edit flow.
///
/// Visibility is a property of each section (and of highlighted passages
/// within it). The **Private** view shows everything; the **Public** view is
/// the filtered projection other users see — public sections only, with
/// `{{private}}` passages stripped. "AI-only" is never shown: a deleted section
/// simply disappears (Ayma keeps it), and a revert can bring it back.
class StoryEditorScreen extends StatefulWidget {
  const StoryEditorScreen({super.key, this.api});

  /// Kept at the old private-wiki path so existing links/routes still work.
  static const path = '/profile/wiki';

  final ApiClient? api;

  @override
  State<StoryEditorScreen> createState() => _StoryEditorScreenState();
}

/// A pending "ask Ayma about this passage" panel.
class _Chat {
  _Chat(this.pageId, this.selection, {required this.inPrivateSpan});
  final String pageId;
  final String selection;
  final bool inPrivateSpan;
}

class _StoryEditorScreenState extends State<StoryEditorScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  String _view = 'private'; // 'private' = everything | 'public' = filtered
  bool _loading = true;
  String? _error;
  List<StorySection> _sections = const [];

  String? _editingId;
  TextEditingController? _editController;
  bool _busy = false;

  _Chat? _chat;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _editController?.dispose();
    super.dispose();
  }

  StorySection? _section(String id) {
    for (final s in _sections) {
      if (s.pageId == id) return s;
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _api.storyGet();
      if (!mounted) return;
      setState(() {
        _sections = data.sections;
        _loading = false;
        if (_editingId != null && _section(_editingId!) == null) {
          _editingId = null;
        }
        if (_chat != null && _section(_chat!.pageId) == null) _chat = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your story ($e).';
        _loading = false;
      });
    }
  }

  List<StorySection> get _visible => _view == 'public'
      ? _sections.where((s) => s.visibility == 'public').toList()
      : _sections;

  // --- section-level actions ---------------------------------------

  void _startEdit(StorySection s) {
    _editController?.dispose();
    _editController = TextEditingController(text: s.body);
    setState(() => _editingId = s.pageId);
  }

  void _cancelEdit() {
    _editController?.dispose();
    _editController = null;
    setState(() => _editingId = null);
  }

  Future<void> _saveEdit(StorySection s) async {
    final c = _editController;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.storySaveSection(pageId: s.pageId, body: c.text);
      _editController?.dispose();
      _editController = null;
      _editingId = null;
      await _load();
      _toast('Saved as new version');
    } catch (e) {
      _toast('Save failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setVisibility(StorySection s, String visibility) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.storySetVisibility(pageId: s.pageId, visibility: visibility);
      await _load();
      _toast('${s.title} is now $visibility');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSection(StorySection s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${s.title}?'),
        content: const Text(
          "It comes out of your story. Ayma keeps it in her memory, and you "
          'can bring it back from version history.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.storyRemoveSection(s.pageId);
      await _load();
      _toast('Deleted ${s.title}');
    } catch (e) {
      _toast('Delete failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- highlight -> chat --------------------------------------------

  void _openChat(StorySection s, String selection) {
    final c = _editController;
    var inSpan = false;
    if (c != null && c.selection.isValid && !c.selection.isCollapsed) {
      final before = c.text.substring(0, c.selection.start);
      inSpan = '{{private}}'.allMatches(before).length >
          '{{/private}}'.allMatches(before).length;
    }
    setState(() => _chat = _Chat(s.pageId, selection, inPrivateSpan: inSpan));
  }

  Future<void> _spanAction(String action) async {
    final chat = _chat;
    if (chat == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.storySpanAction(
        pageId: chat.pageId,
        selection: chat.selection,
        action: action,
      );
      _chat = null;
      _editController?.text = r.body; // keep an open editor in sync
      await _load();
      _toast(action == 'delete'
          ? 'Removed that passage'
          : 'That passage is now $action');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askAyma(String instruction) async {
    final chat = _chat;
    final s = chat == null ? null : _section(chat.pageId);
    if (chat == null || s == null) return;
    final currentBody = _editController?.text ?? s.body;
    late StoryEditResult res;
    try {
      res = await _api.storyEdit(
        pageId: chat.pageId,
        selection: chat.selection,
        instruction: instruction,
      );
    } catch (e) {
      _toast('Edit failed ($e)');
      return;
    }
    if (!mounted) return;
    if (res.usageCapped) {
      _toast("You're out of credits.");
      return;
    }
    setState(() => _chat = null);
    switch (res.action) {
      case 'move':
        unawaited(_setVisibility(s, res.targetVisibility ?? 'public'));
      case 'remove':
        unawaited(_deleteSection(s));
      case 'rewrite':
      default:
        unawaited(_showRewriteDiff(s, currentBody, res.revisedBody));
    }
  }

  Future<void> _showRewriteDiff(
      StorySection s, String oldBody, String newBody) async {
    if (textsEqual(oldBody, newBody)) {
      _toast('Ayma left it unchanged.');
      return;
    }
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _DiffSheet(
        title: 'Suggested edit — ${s.title}',
        oldText: oldBody,
        newText: newBody,
      ),
    );
    if (accepted != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.storySaveSection(pageId: s.pageId, body: newBody);
      _editController?.text = newBody;
      await _load();
      _toast('Saved as new version');
    } catch (e) {
      _toast('Save failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- version timeline -------------------------------------------

  Future<void> _openTimeline() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _VersionTimeline(
        api: _api,
        currentBodies: {for (final s in _sections) s.pageId: s.body},
        currentTitles: {for (final s in _sections) s.pageId: s.title},
        onRevert: (id) async {
          try {
            await _api.storyRevert(versionId: id);
            if (mounted) await _load();
          } catch (e) {
            _toast('Revert failed ($e)');
          }
        },
      ),
    );
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // --- build ----------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Story'),
        actions: [
          IconButton(
            tooltip: 'Version history',
            icon: const Icon(Icons.history),
            onPressed: _loading ? null : _openTimeline,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _ViewToggle(view: _view, onChanged: (v) {
              setState(() {
                _view = v;
                _editingId = null;
                _chat = null;
              });
            }),
          ),
          Divider(height: 0.5, color: ac.lineSoft),
          Expanded(child: _content()),
          if (_chat != null)
            _EditChatPanel(
              section: _section(_chat!.pageId),
              selection: _chat!.selection,
              inPrivateSpan: _chat!.inPrivateSpan,
              busy: _busy,
              onClose: () => setState(() => _chat = null),
              onMakePrivate: () => _spanAction('private'),
              onMakePublic: () => _spanAction('public'),
              onDelete: () => _spanAction('delete'),
              onAsk: _askAyma,
            ),
        ],
      ),
    );
  }

  Widget _content() {
    final ac = context.ac;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 14, color: AymaColors.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    final rows = _visible;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            _view == 'public'
                ? 'Nothing is public yet. Open a section’s ⋯ menu to share it, '
                    'or highlight a line and tell Ayma to make it public.'
                : 'Once you and Ayma have talked a little, your story takes '
                    'shape here.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
          ),
        ),
      );
    }

    final firstSkill = rows.indexWhere((s) => s.isSkill);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      itemCount: rows.length + (firstSkill >= 0 ? 1 : 0),
      itemBuilder: (context, i) {
        var idx = i;
        if (firstSkill >= 0) {
          if (i == firstSkill) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
              child: Row(children: [
                Expanded(child: Divider(color: ac.lineSoft)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text("FROM AYMA'S SKILLS",
                      style: AymaType.mono(size: 9, color: ac.fgMute)
                          .copyWith(letterSpacing: 1.6)),
                ),
                Expanded(child: Divider(color: ac.lineSoft)),
              ]),
            );
          }
          if (i > firstSkill) idx = i - 1;
        }
        final s = rows[idx];
        return _SectionCard(
          key: ValueKey(s.pageId),
          section: s,
          view: _view,
          editing: _editingId == s.pageId,
          editController: _editingId == s.pageId ? _editController : null,
          busy: _busy,
          onEdit: () => _startEdit(s),
          onCancelEdit: _cancelEdit,
          onSave: () => _saveEdit(s),
          onMakePublic: () => _setVisibility(s, 'public'),
          onMakePrivate: () => _setVisibility(s, 'private'),
          onDelete: () => _deleteSection(s),
          onAskSelection: (sel) => _openChat(s, sel),
        );
      },
    );
  }
}

// --- private-span parsing (mirrors story.py) -------------------------

class _Run {
  const _Run(this.text, this.private);
  final String text;
  final bool private;
}

final _spanMarker = RegExp(r'\{\{/?private\}\}');

List<_Run> _parseSpans(String body) {
  final runs = <_Run>[];
  var depth = 0;
  var pos = 0;
  for (final m in _spanMarker.allMatches(body)) {
    final chunk = body.substring(pos, m.start);
    if (chunk.isNotEmpty) runs.add(_Run(chunk, depth > 0));
    depth += m.group(0) == '{{private}}' ? 1 : (depth > 0 ? -1 : 0);
    pos = m.end;
  }
  final tail = body.substring(pos);
  if (tail.isNotEmpty) runs.add(_Run(tail, depth > 0));
  return runs;
}

String _stripPrivateSpans(String body) =>
    _parseSpans(body).where((r) => !r.private).map((r) => r.text).join().trim();

// --- view toggle ----------------------------------------------------

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});

  final String view;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget seg(String value, String label) {
      final on = view == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: on ? ac.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AymaType.sans(
                size: 13,
                weight: FontWeight.w600,
                color: on ? AymaColors.onAccent : ac.fgDim,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Row(children: [
        seg('private', 'Private'),
        seg('public', "What's public"),
      ]),
    );
  }
}

// --- one section card ---------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.section,
    required this.view,
    required this.editing,
    required this.editController,
    required this.busy,
    required this.onEdit,
    required this.onCancelEdit,
    required this.onSave,
    required this.onMakePublic,
    required this.onMakePrivate,
    required this.onDelete,
    required this.onAskSelection,
  });

  final StorySection section;
  final String view;
  final bool editing;
  final TextEditingController? editController;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onCancelEdit;
  final VoidCallback onSave;
  final VoidCallback onMakePublic;
  final VoidCallback onMakePrivate;
  final VoidCallback onDelete;
  final ValueChanged<String> onAskSelection;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = section;
    final isPublic = s.visibility == 'public';
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(s.title,
                    style: AymaType.serif(size: 19, color: ac.fg)),
              ),
              _Pill(
                text: isPublic ? 'public' : 'private',
                color: isPublic ? ac.accent : ac.fgMute,
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_horiz, size: 20, color: ac.fgDim),
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      onEdit();
                    case 'public':
                      onMakePublic();
                    case 'private':
                      onMakePrivate();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit text')),
                  if (isPublic)
                    const PopupMenuItem(
                        value: 'private', child: Text('Make private'))
                  else
                    const PopupMenuItem(
                        value: 'public', child: Text('Make public')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          if (s.aiUpdatedSinceUser && !editing)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome, size: 12, color: ac.accent),
                const SizedBox(width: 6),
                Text('Ayma learned something new here',
                    style: AymaType.sans(size: 11, color: ac.accent)),
              ]),
            ),
          const SizedBox(height: 8),
          if (editing)
            _EditBody(
              controller: editController!,
              busy: busy,
              onSave: onSave,
              onCancel: onCancelEdit,
              onAskSelection: onAskSelection,
            )
          else
            _ReadBody(
              body: view == 'public'
                  ? _stripPrivateSpans(s.body)
                  : s.body,
              showPrivate: view != 'public',
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: AymaType.mono(size: 9, color: color)
              .copyWith(letterSpacing: 0.8)),
    );
  }
}

/// The rendered (markdown) view of a section. `{{private}}` runs render dimmed
/// with a caption; in the Public view they're already stripped upstream.
class _ReadBody extends StatelessWidget {
  const _ReadBody({required this.body, required this.showPrivate});
  final String body;
  final bool showPrivate;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final md = AymaType.serif(size: 15, color: ac.fg).copyWith(height: 1.5);
    if (body.trim().isEmpty) {
      return Text('Nothing here yet.',
          style: AymaType.sans(size: 13, color: ac.fgMute));
    }
    final runs = _parseSpans(body);
    if (!showPrivate || runs.every((r) => !r.private)) {
      return MarkdownText(body.replaceAll(_spanMarker, ''),
          style: md, linkColor: ac.accent);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in runs)
          if (r.text.trim().isEmpty)
            const SizedBox.shrink()
          else if (r.private)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: ac.bgCard,
                borderRadius: BorderRadius.circular(8),
                border: Border(left: BorderSide(color: ac.fgMute, width: 2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PRIVATE — hidden from your public profile',
                      style: AymaType.mono(size: 8, color: ac.fgMute)
                          .copyWith(letterSpacing: 1.2)),
                  const SizedBox(height: 4),
                  MarkdownText(r.text.trim(),
                      style: md.copyWith(color: ac.fgMute),
                      linkColor: ac.accent),
                ],
              ),
            )
          else
            MarkdownText(r.text.trim(), style: md, linkColor: ac.accent),
      ],
    );
  }
}

/// The raw-markdown edit view. Selecting text reveals an "Ask Ayma" affordance
/// that opens the docked chat panel with the selection.
class _EditBody extends StatefulWidget {
  const _EditBody({
    required this.controller,
    required this.busy,
    required this.onSave,
    required this.onCancel,
    required this.onAskSelection,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final ValueChanged<String> onAskSelection;

  @override
  State<_EditBody> createState() => _EditBodyState();
}

class _EditBodyState extends State<_EditBody> {
  String _selection = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final c = widget.controller;
    final sel = c.selection;
    final next = (sel.isValid && !sel.isCollapsed)
        ? sel.textInside(c.text).trim()
        : '';
    if (next != _selection) setState(() => _selection = next);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_selection.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => widget.onAskSelection(_selection),
              icon: const Icon(Icons.auto_awesome, size: 15),
              label: const Text('Ask Ayma about this'),
            ),
          ),
        TextField(
          controller: widget.controller,
          minLines: 4,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: AymaType.sans(size: 14, color: ac.fg).copyWith(height: 1.5),
          decoration: const InputDecoration(
            hintText: 'Write this section in your own words. '
                'Wrap a private aside in {{private}}…{{/private}}.',
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          const Spacer(),
          TextButton(
              onPressed: widget.busy ? null : widget.onCancel,
              child: const Text('Discard')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: widget.busy ? null : widget.onSave,
            child: Text(widget.busy ? 'Saving…' : 'Save'),
          ),
        ]),
      ],
    );
  }
}

// --- docked edit chat panel -------------------------------------

class _EditChatPanel extends StatefulWidget {
  const _EditChatPanel({
    required this.section,
    required this.selection,
    required this.inPrivateSpan,
    required this.busy,
    required this.onClose,
    required this.onMakePrivate,
    required this.onMakePublic,
    required this.onDelete,
    required this.onAsk,
  });

  final StorySection? section;
  final String selection;
  final bool inPrivateSpan;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onMakePrivate;
  final VoidCallback onMakePublic;
  final VoidCallback onDelete;
  final Future<void> Function(String instruction) onAsk;

  @override
  State<_EditChatPanel> createState() => _EditChatPanelState();
}

class _EditChatPanelState extends State<_EditChatPanel> {
  final _instruction = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _instruction.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    await widget.onAsk(t);
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final busy = widget.busy || _sending;
    return Container(
      decoration: BoxDecoration(
        color: ac.bgElev,
        border: Border(top: BorderSide(color: ac.line, width: 0.5)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 10, 8, MediaQuery.of(context).viewInsets.bottom + 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const MiniOrb(size: 12),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'ON THIS PASSAGE${widget.section == null ? '' : ' · ${widget.section!.title.toUpperCase()}'}',
                style: AymaType.mono(size: 9, color: ac.fgMute)
                    .copyWith(letterSpacing: 1.4),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: widget.onClose,
            ),
          ]),
          if (widget.selection.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(right: 8, bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ac.bgCard,
                borderRadius: BorderRadius.circular(10),
                border: Border(left: BorderSide(color: ac.accent, width: 2)),
              ),
              child: Text(widget.selection,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AymaType.serif(size: 13, color: ac.fgDim)),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              if (widget.inPrivateSpan)
                _Chip('Make public', Icons.public,
                    busy ? null : widget.onMakePublic)
              else
                _Chip('Make private', Icons.lock_outline,
                    busy ? null : widget.onMakePrivate),
              _Chip('Delete this', Icons.close, busy ? null : widget.onDelete),
            ]),
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _instruction,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '…or tell Ayma what to change',
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send, size: 20),
              onPressed: busy ? null : _send,
            ),
          ]),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ActionChip(
      avatar: Icon(icon, size: 14, color: ac.fgDim),
      label: Text(label, style: AymaType.sans(size: 12, color: ac.fg)),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

// --- diff view --------------------------------------------------

/// GitHub-style line diff with `+` / `-` gutters and coloured backgrounds,
/// horizontally scrollable, with word-level emphasis on replaced lines.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.oldText, required this.newText});

  final String oldText;
  final String newText;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final lines = diffLines(oldText, newText);
    final mono = AymaType.mono(size: 11, color: ac.fgDim).copyWith(height: 1.5);

    final rows = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final paired = l.kind == DiffKind.delete &&
          i + 1 < lines.length &&
          lines[i + 1].kind == DiffKind.insert;
      Color? bg;
      String gutter;
      Color gutterColor;
      switch (l.kind) {
        case DiffKind.insert:
          bg = ac.success.withValues(alpha: 0.14);
          gutter = '+';
          gutterColor = ac.success;
        case DiffKind.delete:
          bg = ac.error.withValues(alpha: 0.13);
          gutter = '-';
          gutterColor = ac.error;
        case DiffKind.equal:
          bg = null;
          gutter = ' ';
          gutterColor = ac.fgMute;
      }
      InlineSpan content;
      if (paired) {
        content = TextSpan(children: [
          for (final sp in diffWords(l.text, lines[i + 1].text))
            if (sp.kind != DiffKind.insert)
              TextSpan(
                text: sp.text,
                style: sp.kind == DiffKind.delete
                    ? mono.copyWith(color: ac.error, fontWeight: FontWeight.w700)
                    : mono,
              ),
        ]);
      } else if (l.kind == DiffKind.insert &&
          i > 0 &&
          lines[i - 1].kind == DiffKind.delete) {
        content = TextSpan(children: [
          for (final sp in diffWords(lines[i - 1].text, l.text))
            if (sp.kind != DiffKind.delete)
              TextSpan(
                text: sp.text,
                style: sp.kind == DiffKind.insert
                    ? mono.copyWith(
                        color: ac.success, fontWeight: FontWeight.w700)
                    : mono,
              ),
        ]);
      } else {
        content = TextSpan(text: l.text.isEmpty ? ' ' : l.text, style: mono);
      }
      rows.add(Container(
        color: bg,
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 16,
                child: Text(gutter, style: mono.copyWith(color: gutterColor))),
            Text.rich(content),
          ],
        ),
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        ),
      ),
    );
  }
}

class _DiffSheet extends StatelessWidget {
  const _DiffSheet({
    required this.title,
    required this.oldText,
    required this.newText,
  });

  final String title;
  final String oldText;
  final String newText;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AymaType.serif(size: 18, color: ac.fg)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: DiffView(oldText: oldText, newText: newText),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Accept'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// --- version timeline ----------------------------------------

String relativeTime(int ms) {
  if (ms <= 0) return '';
  final d =
      Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - ms);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}

class _VersionTimeline extends StatelessWidget {
  const _VersionTimeline({
    required this.api,
    required this.currentBodies,
    required this.currentTitles,
    required this.onRevert,
  });

  final ApiClient api;
  final Map<String, String> currentBodies;
  final Map<String, String> currentTitles;
  final Future<void> Function(String versionId) onRevert;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Version history',
                style: AymaType.serif(size: 18, color: ac.fg)),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<List<StoryVersion>>(
                future: api.storyVersions(),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final versions = snap.data ?? const <StoryVersion>[];
                  if (versions.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('No versions yet.',
                          style: AymaType.sans(size: 13, color: ac.fgMute)),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: versions.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 0.5, color: ac.lineSoft),
                    itemBuilder: (context, i) {
                      final v = versions[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          v.author == 'ayma'
                              ? Icons.auto_awesome
                              : Icons.person_outline,
                          size: 18,
                          color: v.author == 'ayma' ? ac.accent : ac.fgDim,
                        ),
                        title: Text(v.note.isEmpty ? 'Saved' : v.note,
                            style: AymaType.sans(size: 13, color: ac.fg)),
                        subtitle: Text(
                          [
                            relativeTime(v.createdAtMs),
                            if (v.changedSections.isNotEmpty)
                              v.changedSections.join(', '),
                          ].where((s) => s.isNotEmpty).join(' · '),
                          style: AymaType.sans(size: 11, color: ac.fgMute),
                        ),
                        onTap: () => _openVersion(context, v),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openVersion(BuildContext context, StoryVersion v) async {
    StoryVersionDetail detail;
    try {
      detail = await api.storyVersion(v.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Load failed ($e)')));
      }
      return;
    }
    if (!context.mounted) return;
    final ac = context.ac;
    final changed = [
      for (final s in detail.sections)
        if ((currentBodies[s.pageId] ?? '') != s.body) s,
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(v.note.isEmpty ? 'This version' : v.note,
                  style: AymaType.serif(size: 18, color: ac.fg)),
              const SizedBox(height: 4),
              Text(relativeTime(v.createdAtMs),
                  style: AymaType.sans(size: 11, color: ac.fgMute)),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (changed.isEmpty)
                        Text('Identical to your current story.',
                            style: AymaType.sans(size: 13, color: ac.fgMute))
                      else
                        for (final s in changed) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                            child:
                                Eyebrow(currentTitles[s.pageId] ?? s.title),
                          ),
                          DiffView(
                            oldText: currentBodies[s.pageId] ?? '',
                            newText: s.body,
                          ),
                        ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: ctx,
                    builder: (d) => AlertDialog(
                      title: const Text('Revert'),
                      content: const Text(
                          'Replace your current story with this version? '
                          'Ayma still keeps everything she knows.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const Text('Revert')),
                      ],
                    ),
                  );
                  if (ok == true && ctx.mounted) {
                    Navigator.pop(ctx);
                    if (context.mounted) Navigator.pop(context);
                    await onRevert(v.id);
                  }
                },
                child: const Text('Revert to this version'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
