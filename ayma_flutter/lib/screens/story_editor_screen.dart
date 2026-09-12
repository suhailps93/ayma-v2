import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import 'chat_screen.dart';
import '../theme.dart';
import '../util/text_diff.dart';
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

  // 'private' = Everything | 'public' = What's public | 'ai' = AI notes.
  String _view = 'private';
  bool _loading = true;
  String? _error;
  List<StorySection> _sections = const [];
  List<StorySection> _aiSections = const [];
  List<AiNotePhoto> _photos = const [];

  String? _editingId;
  TextEditingController? _editController;
  bool _busy = false;

  _Sel _sel = const _Sel('', 0, 0, '');

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

        if (_section(_sel.pageId) == null) _sel = const _Sel('', 0, 0, '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your story ($e).';
        _loading = false;
      });
    }
    // AI notes + the photo gallery are secondary to the main document — a
    // failure here shouldn't blank the screen the way a failed storyGet()
    // does, so these are fetched best-effort and just come back empty.
    unawaited(_loadAiNotes());
    unawaited(_loadPhotos());
  }

  Future<void> _loadAiNotes() async {
    try {
      final sections = await _api.storyAiNotes();
      if (mounted) setState(() => _aiSections = sections);
    } catch (e) {
      debugPrint('[story] storyAiNotes failed: $e');
    }
  }

  Future<void> _loadPhotos() async {
    try {
      final notes = await _api.aiNotes();
      if (mounted) setState(() => _photos = notes.photos);
    } catch (e) {
      debugPrint('[story] aiNotes (photos) failed: $e');
    }
  }

  // --- photo actions ---------------------------------------------

  Future<void> _hidePhoto(AiNotePhoto p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.photoHide(p.url, source: p.source);
      await _loadPhotos();
      _toast('Removed that photo');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishPhoto(AiNotePhoto p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.photoPublish(p.url, source: p.source);
      await _loadPhotos();
      _toast('Added to your public profile');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPhoto(AiNotePhoto p) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PhotoDetailSheet(
        photo: p,
        // The sheet awaits these itself and stays open (with an inline busy
        // state) until they resolve, then closes itself — a slow multi-step
        // backend call (moderation + face-embed + captioning for publish)
        // stays visible instead of the sheet just vanishing.
        onHide: () => _hidePhoto(p),
        onPublish: () => _publishPhoto(p),
        onChat: () => _openChatForPhoto(p),
      ),
    );
  }

  Future<void> _openChatForPhoto(AiNotePhoto p) async {
    Navigator.of(context).pop(); // close the photo detail sheet first
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.ac.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.92,
        child: ChatScreen(
          apiClient: widget.api,
          photoUrl: p.url,
          photoSource: p.source,
        ),
      ),
    );
    if (mounted) await _loadPhotos();
  }

  /// "Photos Ayma has" filtered to what this tab actually means: What's
  /// public is only the live public grid; Everything is the private-to-Ayma
  /// working set (grid + chat); AI notes is everything Ayma-only — anything
  /// deleted (wherever it came from), plus unconfirmed web finds.
  List<AiNotePhoto> get _photosForView {
    switch (_view) {
      case 'public':
        return _photos.where((p) => p.source == 'profile' && !p.deleted).toList();
      case 'ai':
        return _photos.where((p) => p.deleted || p.source == 'web').toList();
      default: // 'private' — Everything
        return _photos
            .where((p) =>
                (p.source == 'profile' || p.source == 'chat') && !p.deleted)
            .toList();
    }
  }

  List<StorySection> get _visible {
    if (_view == 'ai') return _aiSections;
    if (_view == 'public') {
      return _sections.where((s) => s.visibility == 'public').toList();
    }
    return _sections;
  }

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

  /// Open the real Ayma chat in a sheet over the editor, scoped to this
  /// section (and passage, if one is highlighted). Voice works there too, and
  /// the exchange shows up in the normal chat history. Ayma edits the passage
  /// with the story tools; every change is a revertable version.
  Future<void> _openChatFor(String pageId, String selection) async {
    _editController?.dispose();
    _editController = null;
    setState(() {
      _editingId = null;
      _sel = const _Sel('', 0, 0, '');
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.ac.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.92,
        child: ChatScreen(
          apiClient: widget.api,
          storyPageId: pageId,
          storyPassage: selection,
        ),
      ),
    );
    if (mounted) await _load(); // pull in whatever Ayma changed
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
                _sel = const _Sel('', 0, 0, '');
              });
            }),
          ),
          const _ColorLegend(),
          Divider(height: 0.5, color: ac.lineSoft),
          Expanded(child: _content()),
          if (_sel.active && _editingId == null)
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
    final photos = _photosForView;
    final showPhotos = photos.isNotEmpty;
    if (rows.isEmpty && !showPhotos) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            _emptyMessage,
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
          ),
        ),
      );
    }

    final firstSkill = rows.indexWhere((s) => s.isSkill);
    return ListView(
      // Wider, book-like margins — this reads as one document, not a stack of
      // cards (matches WikiNarrativeView's margins for the same reason).
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        // Filtered per tab — see _photosForView — so a chat photo doesn't
        // show under "What's public", and a deleted one only shows here.
        if (showPhotos) ...[
          _PhotoSection(photos: photos, onOpen: _openPhoto),
          const SizedBox(height: 28),
        ],
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              _emptyMessage,
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
            ),
          )
        else
          for (var i = 0; i < rows.length; i++) ...[
            if (i == firstSkill)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 18),
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
              ),
            _Section(
              key: ValueKey('${_view}_${rows[i].pageId}'),
              section: rows[i],
              publicView: _view == 'public',
              editing: _editingId == rows[i].pageId && _editController != null,
              editController: _editingId == rows[i].pageId
                  ? _editController
                  : null,
              busy: _busy,
              isLast: i == rows.length - 1,
              onSelect: (a, b, t) =>
                  setState(() => _sel = _Sel(rows[i].pageId, a, b, t)),
              onEdit: () => _startEdit(rows[i]),
              onCancelEdit: _cancelEdit,
              onSave: () => _saveEdit(rows[i]),
              onChat: () => _openChatFor(rows[i].pageId, ''),
              onMakePublic: () => _setVisibility(rows[i], 'public'),
              onMakePrivate: () => _setVisibility(rows[i], 'private'),
              onDelete: () => _deleteSection(rows[i]),
              onHistory: () => _openHistory(rows[i]),
            ),
          ],
      ],
    );
  }

  String get _emptyMessage => switch (_view) {
        'public' => 'Nothing is private — your whole story is public. '
            'Highlight a line to keep just that part to yourself.',
        'ai' => "This fills in as Ayma learns more about you and runs "
            'reports — nothing here yet.',
        _ => 'Once you and Ayma have talked a little, your story takes '
            'shape here.',
      };
}

// --- one section card ---------------------------------------------

/// One chapter of the continuous story document — a heading, its controls,
/// and its flowing body. No card box/background: sections are told apart by a
/// hairline rule between them, not by boxing each one separately, so the
/// whole thing reads as one document rather than a stack of cards.
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.section,
    required this.publicView,
    required this.editing,
    required this.editController,
    required this.busy,
    required this.isLast,
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
  final bool isLast;
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
    // AI-notes sections (§ Your Story AI tab) are Ayma-authored and read-only
    // — no menu, no privacy toggle, no passage editing. Same card, same
    // typography as everything else; just a different badge and no controls.
    final isAi = s.visibility == 'ai';
    final isPublic = s.visibility == 'public';
    // Colour alone carries visibility, top to bottom: black = public, grey =
    // private, red = AI only — matches the legend at the top of the screen.
    final bodyColor = isAi ? ac.error : (isPublic ? ac.fg : ac.fgMute);
    final md = AymaType.serif(size: 16, color: bodyColor).copyWith(height: 1.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(s.title,
                  style: AymaType.serif(size: 20, color: ac.fg)),
            ),
            _Pill(
              text: isAi ? 'AI' : (isPublic ? 'public' : 'private'),
              color: bodyColor,
            ),
            if (s.userEdited && !isAi)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _Pill(text: 'edited', color: ac.fgDim),
              ),
            if (!isAi)
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
        const SizedBox(height: 10),
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
            // An inline {{private}} aside inside an otherwise-public section
            // reads as the same grey a fully private section does.
            privateColor: ac.fgMute,
            publicView: publicView,
            onSelect: isAi ? null : onSelect,
          ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 2),
            child: Divider(height: 0.5, color: ac.lineSoft),
          ),
      ],
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

// --- photos Ayma has -------------------------------------------------

/// One thumbnail's border colour, by where it came from — the same key as
/// the text: public (profile — it's already on the public grid) is black,
/// private (chat — shared with Ayma only) is grey, AI only (web — Ayma found
/// it, not yet confirmed or public — or a photo the user deleted) is red.
Color _photoEdgeColor(BuildContext context, AiNotePhoto p) {
  final ac = context.ac;
  if (p.deleted) return ac.error;
  return switch (p.source) {
    'profile' => ac.fg,
    'chat' => ac.fgMute,
    _ => ac.error, // web
  };
}

/// A photo's *display* group: a deleted photo always shows under "deleted",
/// regardless of where it actually came from — everything else groups by
/// source as usual.
String _displayGroup(AiNotePhoto p) => p.deleted ? 'deleted' : p.source;

const _photoGroups = [
  ('profile', 'PROFILE PHOTOS'),
  ('chat', 'FROM CHAT & SKILLS'),
  ('web', 'FOUND ON THE INTERNET'),
  ('deleted', 'DELETED BY YOU'),
];

/// "PHOTOS AYMA HAS (N)" — every photo Ayma holds of the user, grouped by
/// where it came from (profile grid, chat/skills, or the open web). Shown
/// above the section list on every tab — it isn't itself tagged
/// public/private/AI, but each photo's edge colour says the same thing a
/// section's text colour does.
class _PhotoSection extends StatelessWidget {
  const _PhotoSection({
    required this.photos,
    required this.onOpen,
  });
  final List<AiNotePhoto> photos;
  final void Function(AiNotePhoto) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PHOTOS AYMA HAS (${photos.length})',
          style: AymaType.mono(size: 10, color: ac.fgMute)
              .copyWith(letterSpacing: 1.4),
        ),
        for (final (group, label) in _photoGroups)
          if (photos.any((p) => _displayGroup(p) == group)) ...[
            const SizedBox(height: 14),
            Text('$label (${photos.where((p) => _displayGroup(p) == group).length})',
                style: AymaType.mono(size: 9, color: ac.fgMute)
                    .copyWith(letterSpacing: 1.2)),
            const SizedBox(height: 8),
            _PhotoGallery(
              photos: photos.where((p) => _displayGroup(p) == group).toList(),
              onOpen: onOpen,
            ),
          ],
      ],
    );
  }
}

/// A wrap of square thumbnails, edge-coloured by source; tapping one opens
/// the photo detail sheet (view, note, delete / make public / chat about it).
class _PhotoGallery extends StatelessWidget {
  const _PhotoGallery({required this.photos, required this.onOpen});

  final List<AiNotePhoto> photos;
  final void Function(AiNotePhoto) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in photos)
          InkWell(
            onTap: () => onOpen(p),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: _photoEdgeColor(context, p), width: 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Image.network(
                  p.url,
                  width: 92,
                  height: 92,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 92,
                    height: 92,
                    color: ac.bgElev,
                    child: Icon(Icons.broken_image_outlined,
                        size: 20, color: ac.fgMute),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The photo detail sheet — the big image, Ayma's own read of it (whether
/// it's the user, and what she knows about it), and the three actions:
/// delete (Ayma keeps it, tagged "deleted by you"), make public (add to
/// profile), chat about it — the only way to correct either read is by
/// chatting with Ayma about the photo, never a manual toggle or text box.
class _PhotoDetailSheet extends StatefulWidget {
  const _PhotoDetailSheet({
    required this.photo,
    required this.onHide,
    required this.onPublish,
    required this.onChat,
  });

  final AiNotePhoto photo;

  /// Awaited by the sheet itself, which stays open with an inline busy state
  /// until it resolves (success or failure — the caller handles the toast),
  /// then closes.
  final Future<void> Function() onHide;
  final Future<void> Function() onPublish;
  final VoidCallback onChat;

  @override
  State<_PhotoDetailSheet> createState() => _PhotoDetailSheetState();
}

class _PhotoDetailSheetState extends State<_PhotoDetailSheet> {
  // null | 'hide' | 'publish' — which action (if any) is in flight. Kept
  // local to the sheet so it can show its own busy state and close itself
  // only once the awaited call actually resolves, rather than popping
  // immediately and leaving a slow backend call with no visible feedback.
  String? _acting;

  Future<void> _run(String which, Future<void> Function() action) async {
    if (_acting != null) return;
    setState(() => _acting = which);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _acting = null);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final p = widget.photo;
    final edge = _photoEdgeColor(context, p);
    final label = switch (p.source) {
      'profile' => 'Public — on your profile',
      'chat' => 'Private — shared in chat',
      _ => 'AI only — Ayma found this online',
    };
    final isUserLabel = switch (p.isUser) {
      'yes' => 'Ayma thinks this is you',
      'no' => "Ayma doesn't think this is you",
      _ => "Ayma hasn't checked yet",
    };
    final busy = _acting != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _PhotoViewer(url: p.url),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Image.network(p.url, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color: ac.bgElev,
                          child: Icon(Icons.broken_image_outlined,
                              color: ac.fgMute))),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: edge, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: AymaType.sans(size: 12, color: edge)),
            ]),
            if (p.sourcePage.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Found at ${p.sourcePage}',
                  style: AymaType.sans(size: 11, color: ac.fgMute),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 16),
            Text(isUserLabel,
                style: AymaType.sans(size: 13, color: ac.fgMute)),
            const SizedBox(height: 16),
            Text('What Ayma knows about this photo',
                style: AymaType.sans(size: 12, weight: FontWeight.w600, color: ac.fg)),
            const SizedBox(height: 6),
            Text(
              p.context.isNotEmpty
                  ? p.context
                  : "Ayma hasn't described this photo yet — ask her in chat.",
              style: AymaType.sans(
                size: 13,
                color: p.context.isNotEmpty ? ac.fg : ac.fgMute,
              ),
            ),
            const SizedBox(height: 20),
            if (busy)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(_acting == 'publish' ? 'Publishing…' : 'Deleting…',
                      style: AymaType.sans(size: 13, color: ac.fgMute)),
                ],
              )
            else
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _run('hide', widget.onHide),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                ),
                if (!p.isProfile) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _run('publish', widget.onPublish),
                      icon: const Icon(Icons.public, size: 18),
                      label: const Text('Make public'),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.onChat,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('Chat about it'),
                  ),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: Center(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Icon(Icons.broken_image_outlined,
                      color: Colors.white54, size: 40),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The colour key for the whole document — text colour alone says who can
/// see a passage, so this is the one place that spells the mapping out.
class _ColorLegend extends StatelessWidget {
  const _ColorLegend();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget dot(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(label, style: AymaType.mono(size: 10, color: ac.fgMute)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          dot(ac.fg, 'public'),
          dot(ac.fgMute, 'private'),
          dot(ac.error, 'ai only'),
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
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
            decoration: BoxDecoration(
              color: on ? ac.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AymaType.sans(
                size: 12,
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
        seg('ai', 'AI notes'),
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

/// One history-row's icon/colour/label, from [_SectionHistorySheet._historyKind].
class _HistoryKind {
  const _HistoryKind(this.icon, this.color, this.label);
  final IconData icon;
  final Color color;
  final String label;
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
                      final kind = _historyKind(context, v);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(kind.icon, size: 18, color: kind.color),
                        title: Text(v.note.isEmpty ? 'Edited' : v.note,
                            style: AymaType.sans(size: 13, color: ac.fg)),
                        subtitle: Text(
                          '${relativeTime(v.createdAtMs)} · ${kind.label}',
                          style: AymaType.sans(size: 11, color: kind.color),
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

  /// Categorises one version's note text into the same colour scheme as the
  /// rest of the document, so history reads as fast as the sections do.
  /// Mirrors the exact note strings `story.py` writes: empty = a plain edit,
  /// `"made … public/private"` = a visibility change, `"deleted …"` = a
  /// removal, `"reverted to …"` = a revert, and an Ayma-authored version =
  /// something she learned.
  _HistoryKind _historyKind(BuildContext context, StoryVersion v) {
    final ac = context.ac;
    final note = v.note;
    if (v.author == 'ayma') {
      return _HistoryKind(Icons.auto_awesome, ac.error, 'Ayma learned this');
    }
    if (note.startsWith('deleted ')) {
      return _HistoryKind(Icons.delete_outline, ac.error, 'deleted');
    }
    if (note.startsWith('reverted to ')) {
      return _HistoryKind(Icons.history, ac.accent, 'reverted');
    }
    if (note.startsWith('made ') &&
        (note.endsWith(' public') || note.endsWith(' private'))) {
      final madePublic = note.endsWith(' public');
      return _HistoryKind(
        madePublic ? Icons.public : Icons.lock_outline,
        madePublic ? ac.fg : ac.fgMute,
        madePublic ? 'made public' : 'made private',
      );
    }
    return _HistoryKind(Icons.edit_outlined, ac.fgDim, v.visibility);
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
