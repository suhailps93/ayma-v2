import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/text_diff.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/selectable_markdown.dart';

/// Your Story — one scrolling document over the user's wiki sections.
///
/// Each section reads as rich, **selectable** markdown. Highlight any passage →
/// a toolbar: Make private · Make public · Delete · Ask Ayma. Privacy and
/// delete are exact local body edits (the selection carries raw-body offsets,
/// so nothing has to be matched by text). Every section keeps its own version
/// history, git-log style. "AI-only" is never shown — a deleted section just
/// disappears (Ayma keeps it; a revert brings it back).
class StoryEditorScreen extends StatefulWidget {
  const StoryEditorScreen({super.key, this.api});

  static const path = '/profile/wiki';

  final ApiClient? api;

  @override
  State<StoryEditorScreen> createState() => _StoryEditorScreenState();
}

/// The live text selection inside one section.
class _Sel {
  const _Sel(this.pageId, this.start, this.end, this.text);
  final String pageId;
  final int start; // raw-body offsets
  final int end;
  final String text;
  bool get active => text.trim().isNotEmpty && end > start;
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

  _Sel _sel = const _Sel('', 0, 0, '');
  _ChatState? _chat;

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
        if (_section(_sel.pageId) == null) _sel = const _Sel('', 0, 0, '');
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

  // --- section-level actions --------------------------------------

  void _startEdit(StorySection s) {
    _editController?.dispose();
    _editController = TextEditingController(text: s.body);
    setState(() {
      _editingId = s.pageId;
      _sel = const _Sel('', 0, 0, '');
    });
  }

  void _cancelEdit() {
    _editController?.dispose();
    _editController = null;
    setState(() => _editingId = null);
  }

  Future<void> _saveBody(String pageId, String body, {String? visibility}) async {
    await _api.storySaveSection(
        pageId: pageId, body: body, visibility: visibility);
    await _load();
  }

  Future<void> _saveEdit(StorySection s) async {
    final c = _editController;
    if (c == null || _busy) return;
    final text = c.text;
    setState(() => _busy = true);
    try {
      await _api.storySaveSection(pageId: s.pageId, body: text);
      if (!mounted) return;
      _editController?.dispose();
      _editController = null;
      setState(() => _editingId = null);
      await _load();
      _toast('Saved as a new version');
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
          'can bring it back from this section’s history.',
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

  // --- selection toolbar actions --------------------------------

  Future<void> _applyPrivacy(bool private) async {
    if (!_sel.active || _busy) return;
    final s = _section(_sel.pageId);
    if (s == null) return;
    setState(() => _busy = true);
    try {
      final newBody = setPrivacy(s.body, _sel.start, _sel.end, private);
      await _saveBody(s.pageId, newBody);
      _toast(private ? 'That passage is now private' : 'That passage is public');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) {
        _sel = const _Sel('', 0, 0, '');
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _deleteSelection() async {
    if (!_sel.active || _busy) return;
    final s = _section(_sel.pageId);
    if (s == null) return;
    setState(() => _busy = true);
    try {
      final cut = s.body.substring(0, _sel.start) + s.body.substring(_sel.end);
      await _saveBody(s.pageId, setPrivacy(cut, 0, 0, false).trim());
      _toast('Removed that passage');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) {
        _sel = const _Sel('', 0, 0, '');
        setState(() => _busy = false);
      }
    }
  }

  void _askAyma() {
    if (!_sel.active) return;
    _openChatFor(_sel.pageId, _sel.text);
  }

  void _openChatFor(String pageId, String selection) {
    _editController?.dispose();
    _editController = null;
    setState(() {
      _editingId = null;
      _sel = const _Sel('', 0, 0, '');
      _chat = _ChatState(pageId, selection);
    });
  }

  // --- passage chat thread ------------------------------------

  Future<void> _sendChat(String text) async {
    final chat = _chat;
    final s = chat == null ? null : _section(chat.pageId);
    if (chat == null || s == null) return;
    setState(() {
      chat.messages.add(_Msg.text('user', text));
      chat.sending = true;
    });
    try {
      final r = await _api.storyEdit(
        pageId: chat.pageId,
        selection: chat.selection,
        messages: [
          for (final m in chat.messages)
            if (!m.isProposal) {'role': m.role, 'text': m.text},
        ],
      );
      if (!mounted) return;
      if (r.usageCapped) {
        setState(() => chat.messages
            .add(_Msg.text('ayma', "I'm out of credits — reload on your profile.")));
        return;
      }
      if (r.action == 'move') {
        setState(() => chat.messages.add(_Msg.text('ayma', r.reply.isEmpty
            ? 'Done.'
            : r.reply)));
        await _setVisibility(s, r.targetVisibility ?? 'public');
        if (mounted) setState(() => _chat = null);
        return;
      }
      if (r.action == 'remove') {
        setState(() => _chat = null);
        await _deleteSection(s);
        return;
      }
      setState(() {
        if (r.reply.isNotEmpty) chat.messages.add(_Msg.text('ayma', r.reply));
        if (r.revisedBody.isNotEmpty && r.revisedBody != s.body) {
          chat.messages.add(_Msg.proposal(r.revisedBody));
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() =>
            chat.messages.add(_Msg.text('ayma', "Something went wrong ($e).")));
      }
    } finally {
      if (mounted) setState(() => chat.sending = false);
    }
  }

  Future<void> _acceptProposal(_Msg proposal) async {
    final chat = _chat;
    final s = chat == null ? null : _section(chat.pageId);
    if (s == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _saveBody(s.pageId, proposal.text);
      setState(() => _chat = null);
      _toast('Saved as a new version');
    } catch (e) {
      _toast('Save failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _rejectProposal(_Msg proposal) {
    setState(() {
      _chat?.messages.remove(proposal);
      _chat?.messages.add(_Msg.text('ayma', 'No problem — left it as it was.'));
    });
  }

  // --- per-section history ----------------------------------

  Future<void> _openHistory(StorySection s) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SectionHistorySheet(
        api: _api,
        section: s,
        onRevert: (versionId) async {
          try {
            await _api.storySectionRevert(
                pageId: s.pageId, versionId: versionId);
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
      appBar: AppBar(title: const Text('Your Story')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _ViewToggle(view: _view, onChanged: (v) {
              setState(() {
                _view = v;
                _editingId = null;
                _chat = null;
                _sel = const _Sel('', 0, 0, '');
              });
            }),
          ),
          Divider(height: 0.5, color: ac.lineSoft),
          Expanded(child: _content()),
          if (_chat != null && _section(_chat!.pageId) != null)
            _ChatPanel(
              state: _chat!,
              section: _section(_chat!.pageId)!,
              busy: _busy,
              onClose: () => setState(() => _chat = null),
              onSend: _sendChat,
              onAccept: _acceptProposal,
              onReject: _rejectProposal,
            )
          else if (_sel.active && _editingId == null)
            _SelectionBar(
              busy: _busy,
              onPrivate: () => _applyPrivacy(true),
              onPublic: () => _applyPrivacy(false),
              onDelete: _deleteSelection,
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
                ? 'Nothing is private — your whole story is public. Highlight a '
                    'line to keep just that part to yourself.'
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
        final editingThis = _editingId == s.pageId && _editController != null;
        return _SectionCard(
          key: ValueKey(s.pageId),
          section: s,
          publicView: _view == 'public',
          editing: editingThis,
          editController: editingThis ? _editController : null,
          busy: _busy,
          onSelect: (a, b, t) => setState(
              () => _sel = _Sel(s.pageId, a, b, t)),
          onEdit: () => _startEdit(s),
          onCancelEdit: _cancelEdit,
          onSave: () => _saveEdit(s),
          onChat: () => _openChatFor(s.pageId, ''),
          onMakePublic: () => _setVisibility(s, 'public'),
          onMakePrivate: () => _setVisibility(s, 'private'),
          onDelete: () => _deleteSection(s),
          onHistory: () => _openHistory(s),
        );
      },
    );
  }
}

// --- one section card ---------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.section,
    required this.publicView,
    required this.editing,
    required this.editController,
    required this.busy,
    required this.onSelect,
    required this.onEdit,
    required this.onCancelEdit,
    required this.onSave,
    required this.onChat,
    required this.onMakePublic,
    required this.onMakePrivate,
    required this.onDelete,
    required this.onHistory,
  });

  final StorySection section;
  final bool publicView;
  final bool editing;
  final TextEditingController? editController;
  final bool busy;
  final void Function(int rawStart, int rawEnd, String text) onSelect;
  final VoidCallback onEdit;
  final VoidCallback onCancelEdit;
  final VoidCallback onSave;
  final VoidCallback onChat;
  final VoidCallback onMakePublic;
  final VoidCallback onMakePrivate;
  final VoidCallback onDelete;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = section;
    final isPublic = s.visibility == 'public';
    final md = AymaType.serif(size: 15, color: ac.fg).copyWith(height: 1.5);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    case 'chat':
                      onChat();
                    case 'public':
                      onMakePublic();
                    case 'private':
                      onMakePrivate();
                    case 'delete':
                      onDelete();
                    case 'history':
                      onHistory();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'chat', child: Text('Chat with Ayma')),
                  const PopupMenuItem(value: 'edit', child: Text('Edit text')),
                  if (isPublic)
                    const PopupMenuItem(
                        value: 'private', child: Text('Make section private'))
                  else
                    const PopupMenuItem(
                        value: 'public', child: Text('Make section public')),
                  const PopupMenuItem(
                      value: 'history', child: Text('History')),
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
            )
          else if (s.body.trim().isEmpty)
            Text('Nothing here yet.',
                style: AymaType.sans(size: 13, color: ac.fgMute))
          else
            SelectableMarkdown(
              raw: s.body,
              style: md,
              linkColor: ac.accent,
              publicView: publicView,
              onSelect: onSelect,
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

/// The raw-markdown edit view (⋯ → Edit text).
class _EditBody extends StatelessWidget {
  const _EditBody({
    required this.controller,
    required this.busy,
    required this.onSave,
    required this.onCancel,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          minLines: 4,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: AymaType.sans(size: 14, color: ac.fg).copyWith(height: 1.5),
          decoration: const InputDecoration(
            hintText: 'Write this section in your own words. Wrap a private '
                'aside in {{private}}…{{/private}}.',
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          const Spacer(),
          TextButton(
              onPressed: busy ? null : onCancel, child: const Text('Discard')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: busy ? null : onSave,
            child: Text(busy ? 'Saving…' : 'Save'),
          ),
        ]),
      ],
    );
  }
}

// --- selection toolbar --------------------------------------------

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.busy,
    required this.onPrivate,
    required this.onPublic,
    required this.onDelete,
    required this.onAsk,
  });

  final bool busy;
  final VoidCallback onPrivate;
  final VoidCallback onPublic;
  final VoidCallback onDelete;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: ac.bgElev,
      elevation: 8,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: ac.line, width: 0.5)),
        ),
        padding: EdgeInsets.fromLTRB(
            6, 6, 6, MediaQuery.of(context).padding.bottom + 6),
        child: Row(children: [
          _act(context, Icons.lock_outline, 'Private', busy ? null : onPrivate),
          _act(context, Icons.public, 'Public', busy ? null : onPublic),
          _act(context, Icons.backspace_outlined, 'Delete',
              busy ? null : onDelete),
          _act(context, Icons.auto_awesome, 'Ayma', busy ? null : onAsk),
        ]),
      ),
    );
  }

  Widget _act(BuildContext c, IconData i, String label, VoidCallback? onTap) {
    final ac = c.ac;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(i, size: 20, color: onTap == null ? ac.fgMute : ac.fgDim),
              const SizedBox(height: 4),
              Text(label,
                  style: AymaType.sans(
                      size: 11,
                      color: onTap == null ? ac.fgMute : ac.fg)),
            ],
          ),
        ),
      ),
    );
  }
}

// --- passage chat panel ------------------------------------------

class _Msg {
  _Msg.text(this.role, this.text) : isProposal = false;
  _Msg.proposal(this.text)
      : role = 'ayma',
        isProposal = true;

  final String role; // 'user' | 'ayma'
  final String text; // for a proposal this is the full revised section body
  final bool isProposal;
}

class _ChatState {
  _ChatState(this.pageId, this.selection);
  final String pageId;

  /// The highlighted passage; empty when the whole section is the subject.
  final String selection;
  final List<_Msg> messages = [];
  bool sending = false;

  bool get wholeSection => selection.trim().isEmpty;
}

class _ChatPanel extends StatefulWidget {
  const _ChatPanel({
    required this.state,
    required this.section,
    required this.busy,
    required this.onClose,
    required this.onSend,
    required this.onAccept,
    required this.onReject,
  });

  final _ChatState state;
  final StorySection section;
  final bool busy;
  final VoidCallback onClose;
  final Future<void> Function(String text) onSend;
  final Future<void> Function(_Msg proposal) onAccept;
  final void Function(_Msg proposal) onReject;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_ChatPanel old) {
    super.didUpdateWidget(old);
    // Keep the newest message in view as the thread grows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _input.text.trim();
    if (t.isEmpty || widget.state.sending) return;
    _input.clear();
    await widget.onSend(t);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final st = widget.state;
    final subject =
        st.wholeSection ? 'ABOUT ${widget.section.title.toUpperCase()}' : 'ON A PASSAGE';
    // The Scaffold already lifts its body above the keyboard
    // (resizeToAvoidBottomInset), so only the safe-area inset is added here —
    // adding viewInsets too double-counts and overflows the panel.
    return Material(
      color: ac.bgElev,
      elevation: 16,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            14, 6, 8, MediaQuery.of(context).padding.bottom + 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // grabber
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: ac.lineSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(children: [
              const MiniOrb(size: 13),
              const SizedBox(width: 8),
              Expanded(
                child: Text('AYMA · $subject',
                    style: AymaType.mono(size: 9, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.4),
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: widget.onClose),
            ]),
            if (!st.wholeSection)
              Container(
                margin: const EdgeInsets.only(right: 8, bottom: 6),
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: ac.bgCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border(left: BorderSide(color: ac.accent, width: 2)),
                ),
                child: Text('“${st.selection}”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AymaType.serif(size: 13, color: ac.fgDim)),
              ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.34,
                ),
                child: st.messages.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          st.wholeSection
                              ? 'Tell Ayma what to change in this section.'
                              : 'Tell Ayma what to do with this bit.',
                          style: AymaType.sans(size: 13, color: ac.fgMute),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        reverse: true,
                        padding: const EdgeInsets.only(right: 8, bottom: 4),
                        itemCount: st.messages.length,
                        itemBuilder: (c, i) {
                          final m = st.messages[st.messages.length - 1 - i];
                          if (m.isProposal) {
                            return _ProposalCard(
                              oldText: widget.section.body,
                              newText: m.text,
                              busy: widget.busy || st.sending,
                              onAccept: () => widget.onAccept(m),
                              onReject: () => widget.onReject(m),
                            );
                          }
                          final mine = m.role == 'user';
                          return Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 3),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(c).size.width * 0.78),
                              decoration: BoxDecoration(
                                color: mine ? ac.accentFaint : ac.bgCard,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(m.text,
                                  style: mine
                                      ? AymaType.sans(size: 14, color: ac.fg)
                                      : AymaType.serif(size: 15, color: ac.fg)
                                          .copyWith(height: 1.35)),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  onSubmitted: (_) => _send(),
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    hintText: 'Tell Ayma what to change…',
                    isDense: true,
                    filled: true,
                    fillColor: ac.bgCard,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: st.sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_upward_rounded, size: 22),
                onPressed: st.sending ? null : _send,
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Ayma's proposed rewrite, shown inline in the thread as a phone-readable
/// diff (wrapping prose, removed words struck through, added words tinted) with
/// Accept / Reject right there — no separate sheet.
class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.oldText,
    required this.newText,
    required this.busy,
    required this.onAccept,
    required this.onReject,
  });

  final String oldText;
  final String newText;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      margin: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('PROPOSED CHANGE',
              style: AymaType.mono(size: 8, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Text.rich(
                TextSpan(children: [
                  for (final sp in diffWords(oldText, newText))
                    if (sp.kind == DiffKind.equal)
                      TextSpan(
                          text: sp.text,
                          style: AymaType.serif(size: 14, color: ac.fgDim)
                              .copyWith(height: 1.4))
                    else if (sp.kind == DiffKind.delete)
                      TextSpan(
                          text: sp.text,
                          style: AymaType.serif(size: 14, color: ac.error)
                              .copyWith(
                                  height: 1.4,
                                  decoration: TextDecoration.lineThrough))
                    else
                      TextSpan(
                          text: sp.text,
                          style: AymaType.serif(
                                  size: 14,
                                  color: ac.fg,
                                  weight: FontWeight.w600)
                              .copyWith(
                                  height: 1.4,
                                  backgroundColor:
                                      ac.success.withValues(alpha: 0.18))),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: busy ? null : onReject,
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(38)),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: busy ? null : onAccept,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(38)),
                child: const Text('Accept'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

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
        seg('private', 'Everything'),
        seg('public', "What's public"),
      ]),
    );
  }
}

// --- per-section history sheet --------------------------------

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

class _SectionHistorySheet extends StatelessWidget {
  const _SectionHistorySheet({
    required this.api,
    required this.section,
    required this.onRevert,
  });

  final ApiClient api;
  final StorySection section;
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
            Text('${section.title} · history',
                style: AymaType.serif(size: 18, color: ac.fg)),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<List<StoryVersion>>(
                future: api.storySectionVersions(section.pageId),
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
                      child: Text('No earlier versions of this section yet.',
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
                          '${relativeTime(v.createdAtMs)} · ${v.visibility}',
                          style: AymaType.sans(size: 11, color: ac.fgMute),
                        ),
                        onTap: () => _open(context, v),
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

  Future<void> _open(BuildContext context, StoryVersion v) async {
    StorySectionVersion detail;
    try {
      detail = await api.storySectionVersion(section.pageId, v.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Load failed ($e)')));
      }
      return;
    }
    if (!context.mounted) return;
    final ac = context.ac;
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
              Text('${relativeTime(v.createdAtMs)} · ${detail.visibility}',
                  style: AymaType.sans(size: 11, color: ac.fgMute)),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: detail.body == section.body
                      ? Text('Identical to the current version.',
                          style: AymaType.sans(size: 13, color: ac.fgMute))
                      : DiffView(oldText: section.body, newText: detail.body),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (context.mounted) Navigator.pop(context);
                  await onRevert(v.id);
                },
                child: const Text('Revert this section to here'),
              ),
            ],
          ),
        ),
      ),
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
