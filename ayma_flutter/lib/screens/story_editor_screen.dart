import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/text_diff.dart';
import '../widgets/ayma_primitives.dart';

/// Your Story — a codebase/IDE-style editor over the user's wiki sections, with
/// version history, diffs, revert, and a highlight-to-chat edit flow. The same
/// editor edits a **Private** story and a **Public** profile text, switched
/// with the toggle at the top. AI-only pages are never shown here.
class StoryEditorScreen extends StatefulWidget {
  const StoryEditorScreen({super.key, this.api});

  /// Kept at the old private-wiki path so existing links/routes still work.
  static const path = '/profile/wiki';

  final ApiClient? api;

  @override
  State<StoryEditorScreen> createState() => _StoryEditorScreenState();
}

class _StoryEditorScreenState extends State<StoryEditorScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  String _side = 'private';
  bool _loading = true;
  String? _error;
  List<StorySection> _sections = const [];

  String? _selectedId;
  TextEditingController? _controller;
  String _pendingVisibility = 'private';
  bool _seedStarted = false;
  bool _saving = false;

  String _selection = '';
  bool _chatOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  StorySection? get _selected {
    final id = _selectedId;
    if (id == null) return null;
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
      final data = await _api.storyGet(_side);
      if (!mounted) return;
      setState(() {
        _sections = data.sections;
        _loading = false;
        if (_selectedId == null ||
            !_sections.any((s) => s.pageId == _selectedId)) {
          _selectedId = _sections.isEmpty ? null : _sections.first.pageId;
        }
        _bindController();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your story ($e).';
        _loading = false;
      });
    }
  }

  void _bindController() {
    _controller?.removeListener(_onEditorChanged);
    _controller?.dispose();
    final s = _selected;
    _controller = TextEditingController(text: s?.body ?? '')
      ..addListener(_onEditorChanged);
    _pendingVisibility = s?.visibility ?? 'private';
    _seedStarted = false;
    _selection = '';
  }

  void _onEditorChanged() {
    final c = _controller;
    if (c == null) return;
    final sel = c.selection;
    final next = (sel.isValid && !sel.isCollapsed)
        ? sel.textInside(c.text).trim()
        : '';
    // Rebuild on every change so the dirty-state Save / Discard and the
    // selection affordance both stay current.
    setState(() => _selection = next);
  }

  bool get _dirty {
    final s = _selected;
    final c = _controller;
    if (s == null || c == null) return false;
    return c.text != s.body || _pendingVisibility != s.visibility;
  }

  Future<void> _switchSide(String side) async {
    if (side == _side) return;
    setState(() {
      _side = side;
      _selectedId = null;
      _chatOpen = false;
    });
    await _load();
  }

  void _selectSection(String id) {
    setState(() {
      _selectedId = id;
      _chatOpen = false;
      _bindController();
    });
  }

  Future<void> _save() async {
    final s = _selected;
    final c = _controller;
    if (s == null || c == null || _saving) return;
    setState(() => _saving = true);
    try {
      await _api.storySaveSection(
        pageId: s.pageId,
        side: _side,
        body: c.text,
        visibility: _pendingVisibility == s.visibility ? null : _pendingVisibility,
      );
      if (!mounted) return;
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved as new version')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed ($e)')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _discard() {
    setState(_bindController);
  }

  Future<void> _seedPublic({required bool regenerate}) async {
    final s = _selected;
    if (s == null) return;
    setState(() => _saving = true);
    try {
      final draft = await _api.storySeedPublic(s.pageId);
      if (!mounted) return;
      if (draft.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't draft a version right now.")),
        );
      } else {
        setState(() {
          _seedStarted = true;
          _controller?.text = draft;
        });
        if (regenerate) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Regenerated — review and save.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Seed failed ($e)')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- edit chat flow -------------------------------------------------

  Future<void> _runEdit(String instruction) async {
    final s = _selected;
    final c = _controller;
    if (s == null || c == null) return;
    final currentBody = c.text;
    late StoryEditResult res;
    try {
      res = await _api.storyEdit(
        pageId: s.pageId,
        side: _side,
        selection: _selection,
        instruction: instruction,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Edit failed ($e)')));
      }
      return;
    }
    if (!mounted) return;

    if (res.usageCapped) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're out of credits.")),
      );
      return;
    }

    // Collapse the chat panel before the diff sheet / confirm dialog opens —
    // its send affordance is done, and this keeps `_runEdit` from awaiting the
    // whole downstream interaction.
    setState(() => _chatOpen = false);
    switch (res.action) {
      case 'move':
        unawaited(_confirmMove(s, res.targetSide ?? 'public'));
      case 'remove':
        unawaited(_confirmRemove(s));
      case 'rewrite':
      default:
        unawaited(_showRewriteDiff(s, currentBody, res.revisedBody));
    }
  }

  Future<void> _showRewriteDiff(
      StorySection s, String oldBody, String newBody) async {
    if (textsEqual(oldBody, newBody)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ayma left it unchanged.')),
      );
      return;
    }
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _DiffSheet(
        title: 'Suggested edit — ${s.title}',
        oldText: oldBody,
        newText: newBody,
        acceptLabel: 'Accept',
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      _chatOpen = false;
      _controller?.text = newBody;
    });
    try {
      await _api.storySaveSection(
        pageId: s.pageId,
        side: _side,
        body: newBody,
      );
      if (!mounted) return;
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved as new version')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed ($e)')));
      }
    }
  }

  Future<void> _confirmMove(StorySection s, String targetSide) async {
    final dest =
        targetSide == 'public' ? 'your Public profile' : 'your Private story';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move section'),
        content: Text('Move ${s.title} to $dest?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Move')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _chatOpen = false);
    try {
      await _api.storyMoveSection(
        pageId: s.pageId,
        targetSide: targetSide,
      );
      if (!mounted) return;
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Moved ${s.title} to $dest')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Move failed ($e)')));
      }
    }
  }

  Future<void> _confirmRemove(StorySection s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove section'),
        content: Text(
          'Remove ${s.title} from your story? Ayma keeps it in her private '
          'memory.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _chatOpen = false);
    try {
      await _api.storyRemoveSection(s.pageId);
      if (!mounted) return;
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed ${s.title}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Remove failed ($e)')));
      }
    }
  }

  // --- version timeline ---------------------------------------------

  Future<void> _openTimeline() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _VersionTimeline(
        api: _api,
        side: _side,
        currentBodies: {for (final s in _sections) s.pageId: s.body},
        currentTitles: {for (final s in _sections) s.pageId: s.title},
        onRevert: (versionId) async {
          try {
            await _api.storyRevert(versionId: versionId, side: _side);
            if (mounted) await _load();
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('Revert failed ($e)')));
            }
          }
        },
      ),
    );
  }

  // --- build ------------------------------------------------------

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
            child: _SideToggle(side: _side, onChanged: _switchSide),
          ),
          Divider(height: 0.5, color: ac.lineSoft),
          Expanded(child: _bodyContent()),
        ],
      ),
    );
  }

  Widget _bodyContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: AymaType.sans(size: 14, color: AymaColors.error)),
        ),
      );
    }
    if (_sections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            _side == 'public'
                ? 'Nothing to share yet — build your private story first.'
                : 'Once you and Ayma have talked a little, your story will '
                    'take shape here.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, soft: true, color: context.ac.fgMute),
          ),
        ),
      );
    }
    final ac = context.ac;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 168,
          child: _SectionTree(
            sections: _sections,
            selectedId: _selectedId,
            onSelect: _selectSection,
          ),
        ),
        VerticalDivider(width: 0.5, color: ac.lineSoft),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _editorArea()),
              if (_chatOpen && _selected != null)
                _EditChatPanel(
                  selection: _selection,
                  sectionTitle: _selected!.title,
                  onClose: () => setState(() => _chatOpen = false),
                  onSend: _runEdit,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _editorArea() {
    final s = _selected;
    final c = _controller;
    if (s == null || c == null) {
      return const SizedBox.shrink();
    }
    final ac = context.ac;
    final showSeedCard =
        _side == 'public' && s.needsSeed && !_seedStarted && c.text.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(s.title, style: AymaType.serif(size: 22, color: ac.fg)),
            ),
            IconButton(
              tooltip: 'Ask Ayma about a passage',
              icon: const Icon(Icons.forum_outlined, size: 20),
              onPressed: () => setState(() => _chatOpen = true),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _VisibilityDropdown(
          value: _pendingVisibility,
          onChanged: (v) => setState(() => _pendingVisibility = v),
        ),
        const SizedBox(height: 14),
        if (showSeedCard)
          _SeedCard(
            busy: _saving,
            onDraft: () => _seedPublic(regenerate: false),
            onBlank: () => setState(() => _seedStarted = true),
          )
        else ...[
          if (_selection.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextButton.icon(
                  onPressed: () => setState(() => _chatOpen = true),
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Ask Ayma about this'),
                ),
              ),
            ),
          TextField(
            controller: c,
            minLines: 8,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: AymaType.serif(size: 15, color: ac.fg).copyWith(height: 1.5),
            decoration: const InputDecoration(
              hintText: 'Write this section in your own words',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_side == 'public' && (_seedStarted || !s.needsSeed))
                TextButton.icon(
                  onPressed: _saving ? null : () => _seedPublic(regenerate: true),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Regenerate'),
                ),
              const Spacer(),
              if (_dirty) ...[
                TextButton(
                  onPressed: _saving ? null : _discard,
                  child: const Text('Discard'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

// --- side toggle ------------------------------------------------------

class _SideToggle extends StatelessWidget {
  const _SideToggle({required this.side, required this.onChanged});

  final String side;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget seg(String value, String label) {
      final on = side == value;
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
      child: Row(children: [seg('private', 'Private'), seg('public', 'Public')]),
    );
  }
}

// --- section tree ---------------------------------------------------

class _SectionTree extends StatelessWidget {
  const _SectionTree({
    required this.sections,
    required this.selectedId,
    required this.onSelect,
  });

  final List<StorySection> sections;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sections.length,
      itemBuilder: (context, i) {
        final s = sections[i];
        final on = s.pageId == selectedId;
        final edited = s.userEdited;
        return InkWell(
          onTap: () => onSelect(s.pageId),
          child: Container(
            color: on ? ac.accentFaint : null,
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AymaType.sans(
                      size: 13,
                      color: on ? ac.fg : ac.fgDim,
                      weight: on ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (s.aiUpdatedSinceUser)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.auto_awesome,
                        size: 11, color: ac.accent),
                  )
                else if (edited)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration:
                          BoxDecoration(color: ac.fgMute, shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- visibility dropdown ------------------------------------------

class _VisibilityDropdown extends StatelessWidget {
  const _VisibilityDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const _labels = {
    'private': 'Private',
    'public': 'Public',
    'ai_only': 'AI-only',
  };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      children: [
        Icon(Icons.visibility_outlined, size: 15, color: ac.fgMute),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: value,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: AymaType.sans(size: 13, color: ac.fg),
          items: [
            for (final e in _labels.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

// --- seed card ----------------------------------------------------

class _SeedCard extends StatelessWidget {
  const _SeedCard({
    required this.busy,
    required this.onDraft,
    required this.onBlank,
  });

  final bool busy;
  final VoidCallback onDraft;
  final VoidCallback onBlank;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(18),
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
              const MiniOrb(),
              const SizedBox(width: 8),
              Text('Nothing public here yet',
                  style: AymaType.serif(size: 17, color: ac.fg)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Let Ayma draft a shareable version from your private story — '
            'tightened, with the sensitive parts left out.',
            style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : onDraft,
                child: Text(busy ? 'Drafting…' : 'Draft a version'),
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: busy ? null : onBlank, child: const Text('Start blank')),
            ],
          ),
        ],
      ),
    );
  }
}

// --- edit chat panel -------------------------------------------

class _EditChatPanel extends StatefulWidget {
  const _EditChatPanel({
    required this.selection,
    required this.sectionTitle,
    required this.onClose,
    required this.onSend,
  });

  final String selection;
  final String sectionTitle;
  final VoidCallback onClose;
  final Future<void> Function(String instruction) onSend;

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
    final text = _instruction.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    await widget.onSend(text);
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      decoration: BoxDecoration(
        color: ac.bgElev,
        border: Border(top: BorderSide(color: ac.line, width: 0.5)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 12, 8, MediaQuery.of(context).viewInsets.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const MiniOrb(size: 12),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Ask Ayma to edit ${widget.sectionTitle}',
                    style: AymaType.mono(size: 10, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.5)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onClose,
              ),
            ],
          ),
          if (widget.selection.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(right: 8, bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ac.bgCard,
                borderRadius: BorderRadius.circular(10),
                border: Border(left: BorderSide(color: ac.accent, width: 2)),
              ),
              child: Text(
                widget.selection,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AymaType.serif(size: 13, color: ac.fgDim),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _instruction,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'e.g. make this warmer, or drop the last line',
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
                onPressed: _sending ? null : _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- diff view --------------------------------------------------

/// GitHub-style line diff with `+` / `-` gutters and coloured backgrounds,
/// horizontally scrollable. Deleted lines that are immediately replaced get a
/// word-level emphasis.
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
        content = TextSpan(
          children: [
            for (final sp in diffWords(l.text, lines[i + 1].text))
              if (sp.kind != DiffKind.insert)
                TextSpan(
                  text: sp.text,
                  style: sp.kind == DiffKind.delete
                      ? mono.copyWith(
                          color: ac.error, fontWeight: FontWeight.w700)
                      : mono,
                ),
          ],
        );
      } else if (l.kind == DiffKind.insert &&
          i > 0 &&
          lines[i - 1].kind == DiffKind.delete) {
        content = TextSpan(
          children: [
            for (final sp in diffWords(lines[i - 1].text, l.text))
              if (sp.kind != DiffKind.delete)
                TextSpan(
                  text: sp.text,
                  style: sp.kind == DiffKind.insert
                      ? mono.copyWith(
                          color: ac.success, fontWeight: FontWeight.w700)
                      : mono,
                ),
          ],
        );
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
              child: Text(gutter, style: mono.copyWith(color: gutterColor)),
            ),
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
    this.acceptLabel = 'Accept',
  });

  final String title;
  final String oldText;
  final String newText;
  final String acceptLabel;

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
            Row(
              children: [
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
                    child: Text(acceptLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- version timeline ----------------------------------------

String relativeTime(int ms) {
  if (ms <= 0) return '';
  final d = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - ms);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}

class _VersionTimeline extends StatelessWidget {
  const _VersionTimeline({
    required this.api,
    required this.side,
    required this.currentBodies,
    required this.currentTitles,
    required this.onRevert,
  });

  final ApiClient api;
  final String side;
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
            Text('Version history · ${side == 'public' ? 'Public' : 'Private'}',
                style: AymaType.serif(size: 18, color: ac.fg)),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<List<StoryVersion>>(
                future: api.storyVersions(side),
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
                        title: Text(
                          v.note.isEmpty ? 'Saved' : v.note,
                          style: AymaType.sans(size: 13, color: ac.fg),
                        ),
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
                            style:
                                AymaType.sans(size: 13, color: ac.fgMute))
                      else
                        for (final s in changed) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                            child: Eyebrow(
                                currentTitles[s.pageId] ?? s.title),
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
                      content: Text(
                          'Replace your current ${side == 'public' ? 'public profile' : 'private story'} with this version?'),
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
