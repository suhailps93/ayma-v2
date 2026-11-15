import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'ask_ayma_overlay.dart';
import 'ayma_toast.dart';
import 'bullet_visibility.dart';
import 'overflow_guards.dart';

/// Splits free text into one sentence per bullet (the server does the same on
/// save; doing it here lets the user see each sentence as its own bullet).
List<String> splitIntoBullets(String text) => text
    .trim()
    .split(RegExp(r'(?<=[.!?])\s+|\n+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// Every canonical story section (`GET /profile/bullets`) as a card of
/// bullets: title, subtitle, a per-bullet visibility control, and a "+"
/// under each section — empty sections included, so it works for a user who
/// has never talked to Ayma. Each change saves its section straight away.
class BulletSectionsEditor extends StatefulWidget {
  const BulletSectionsEditor({super.key, required this.api});

  final ApiClient api;

  @override
  State<BulletSectionsEditor> createState() => _BulletSectionsEditorState();
}

class _BulletSectionsEditorState extends State<BulletSectionsEditor> {
  List<BulletSection> _sections = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final s = await widget.api.profileBullets();
      if (!mounted) return;
      setState(() {
        _sections = [...s]..sort((a, b) => a.order.compareTo(b.order));
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your story ($e).';
        _loading = false;
      });
    }
  }

  /// Persists [bullets] for [section]; false (with a toast) on failure.
  Future<bool> _save(BulletSection section, List<StoryBullet> bullets) async {
    try {
      if (section.pageId.isEmpty) {
        await widget.api.profileBulletsCreate(section.pageType, bullets);
      } else {
        await widget.api.profileBulletsSave(section.pageId, bullets);
      }
    } catch (e) {
      if (mounted) {
        AymaToast.show(
          context,
          "Couldn't save that change. Please try again.",
          kind: AymaToastKind.error,
        );
      }
      return false;
    }
    await _load(silent: true);
    return true;
  }

  /// Open a scoped Ask-Ayma chat about ONE bullet (founder order, Nov 15 2026).
  /// Reuses the shared Ask-Ayma overlay / reply-style machinery: it sends only
  /// the section reference (`story_page_id`) + the bullet as the scoped passage
  /// (`story_passage`) — Ayma's existing story_edit tools act on that exact
  /// bullet (edit wording, make public/private, remove). No parallel system.
  Future<void> _chat(BulletSection section, StoryBullet bullet) async {
    if (section.pageId.isEmpty || bullet.text.trim().isEmpty) return;
    await showAskAymaOverlay(
      context,
      api: widget.api,
      ctx: AskAymaContext(
        origin: AskAymaOrigin.story,
        pageId: section.pageId,
        selectedText: bullet.text,
        sectionTitle: section.title,
        isPrivate: bullet.visibility != 'public',
        quoteTitle: section.title,
        quoteText: bullet.text,
      ),
      // After each reply, re-pull so an edit Ayma made to the bullet shows.
      onExchange: () => _load(silent: true),
    );
    if (mounted) await _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return CenteredScroll(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, color: ac.errorText),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _load,
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final seenKeys = <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _sections.length; i++)
          BulletSectionCard(
            key: ValueKey(() {
              final s = _sections[i];
              final base = s.pageId.isNotEmpty ? s.pageId : s.pageType;
              final keyStr = 'bullet_section_$base';
              return seenKeys.add(keyStr) ? keyStr : '${keyStr}_$i';
            }()),
            section: _sections[i],
            onSave: (bullets) => _save(_sections[i], bullets),
            onChat: (bullet) => _chat(_sections[i], bullet),
          ),
      ],
    );
  }
}

/// One section: title, subtitle, its bullets and the "+" that adds one.
class BulletSectionCard extends StatefulWidget {
  const BulletSectionCard({
    super.key,
    required this.section,
    required this.onSave,
    required this.onChat,
  });

  final BulletSection section;
  final Future<bool> Function(List<StoryBullet> bullets) onSave;
  final void Function(StoryBullet bullet) onChat;

  @override
  State<BulletSectionCard> createState() => _BulletSectionCardState();
}

/// Ayma-only bullets are never shown in Your Story (founder order, Nov 15
/// 2026). The backend already strips them from `/profile/bullets`; this is a
/// belt-and-braces guard on the render path so one can never slip through.
List<StoryBullet> _visibleBullets(BulletSection s) =>
    s.bullets.where((b) => !b.isAiOnly).toList();

class _BulletSectionCardState extends State<BulletSectionCard> {
  late List<StoryBullet> _bullets = _visibleBullets(widget.section);
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  int? _editing;
  // Whether the open editor is a brand-new bullet (from "+ Add") or an edit of
  // an existing one. A new bullet auto-splits multi-sentence input into one
  // bullet per sentence; editing an existing bullet stays a single bullet
  // (Scout NOTE 221) so appended text is never split off into its own bullet.
  bool _editingIsNew = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_commit());
    });
  }

  @override
  void didUpdateWidget(BulletSectionCard old) {
    super.didUpdateWidget(old);
    if (_editing == null && !_saving) {
      _bullets = _visibleBullets(widget.section);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit(int i) {
    if (_saving) return;
    setState(() {
      _editing = i;
      _editingIsNew = false;
      _ctrl.text = _bullets[i].text;
    });
    _focus.requestFocus();
  }

  void _startAdd() {
    if (_saving) return;
    unawaited(_commit());
    setState(() {
      _bullets = [
        ..._bullets,
        const StoryBullet(text: '', visibility: 'private'),
      ];
      _editing = _bullets.length - 1;
      _editingIsNew = true;
      _ctrl.clear();
    });
    _focus.requestFocus();
  }

  /// Folds the open editor's text into `_bullets` and closes the editor. A
  /// brand-new bullet (from "+ Add") auto-splits multi-sentence input into one
  /// bullet per sentence; editing an existing bullet stays a SINGLE bullet and
  /// keeps its visibility tag — appended text is never split off into its own
  /// (public) bullet (Scout NOTE 221). An emptied text drops the bullet. Pure
  /// state mutation: no setState and no save (the caller owns both), so a
  /// commit and a visibility cycle in the same gesture save exactly once.
  /// Returns whether anything changed and whether the edited bullet still
  /// exists at its index afterwards.
  ({bool changed, bool kept}) _foldOpenEdit() {
    final i = _editing;
    if (i == null || i >= _bullets.length) {
      return (changed: false, kept: true);
    }
    final vis = _bullets[i].visibility;
    final List<StoryBullet> replacement;
    final bool changed;
    if (_editingIsNew) {
      final pieces = splitIntoBullets(_ctrl.text);
      replacement = [for (final p in pieces) StoryBullet(text: p, visibility: vis)];
      changed = !(pieces.length == 1 && pieces.first == _bullets[i].text);
    } else {
      final text = _ctrl.text.trim();
      replacement =
          text.isEmpty ? const [] : [StoryBullet(text: text, visibility: vis)];
      changed = text != _bullets[i].text;
    }
    _editing = null;
    _bullets = [
      ..._bullets.sublist(0, i),
      ...replacement,
      ..._bullets.sublist(i + 1),
    ];
    return (changed: changed, kept: replacement.isNotEmpty);
  }

  /// Finishes the open edit (focus loss / submit) and saves if it changed.
  Future<void> _commit() async {
    if (_editing == null) return;
    final r = _foldOpenEdit();
    if (mounted) setState(() {});
    if (r.changed) await _persist();
  }

  /// Serialises saves: a change made while a save is in flight (e.g. a quick
  /// second visibility tap) doesn't start a second concurrent write — it marks
  /// a re-save that runs with the latest `_bullets` once the current one
  /// finishes, so the last value the user picked is the one that persists.
  bool _resaveNeeded = false;

  Future<void> _persist() async {
    if (_saving) {
      // A save is already running — fold this change into it (re-save after).
      _resaveNeeded = true;
      return;
    }
    setState(() => _saving = true);
    var ok = await widget.onSave(_bullets);
    while (ok && _resaveNeeded && mounted) {
      _resaveNeeded = false;
      ok = await widget.onSave(_bullets);
    }
    _resaveNeeded = false;
    if (!mounted) return;
    setState(() {
      _saving = false;
      // A failed save is never silent: onSave has already toasted. Snap the
      // bullets back to the server's truth so the UI can't show a change that
      // didn't land.
      if (!ok) _bullets = _visibleBullets(widget.section);
    });
  }

  /// Cycles one bullet's visibility (public <-> private). Stays live during a
  /// save — the flip is optimistic and [_persist] serialises the writes — so a
  /// tap is never a dead no-op (Scout NOTE 219 leg a). If the tapped bullet is
  /// open in the editor, its typed text is committed first (kept, not lost), so
  /// one tap = commit + cycle; closing the editor here also means the focus-
  /// loss auto-commit this same tap triggers finds nothing open and can't race
  /// it. One save covers both the committed text and the new visibility.
  void _cycle(int i) {
    if (i < 0 || i >= _bullets.length) return;
    if (_editing == i) {
      final r = _foldOpenEdit();
      if (!r.kept) {
        // The edit had emptied the bullet, so it's gone — just save the change.
        setState(() {});
        unawaited(_persist());
        return;
      }
    } else if (_editing != null) {
      // A different bullet is open — commit it first. A single-line commit
      // doesn't shift indices; guard the (rare) multi-line case below.
      _foldOpenEdit();
      if (i >= _bullets.length) {
        setState(() {});
        unawaited(_persist());
        return;
      }
    }
    setState(() {
      _bullets[i] = StoryBullet(
        text: _bullets[i].text,
        visibility: nextBulletVisibility(_bullets[i].visibility),
      );
    });
    unawaited(_persist());
  }

  void _delete(int i) {
    if (_saving) return;
    setState(() => _bullets.removeAt(i));
    unawaited(_persist());
  }

  /// Asks before deleting a bullet — tapping the trash icon used to delete
  /// instantly (how a Scout test bullet vanished during NOTE 219). Deletes only
  /// after the user confirms; Cancel leaves the bullet untouched.
  Future<void> _confirmDelete(int i) async {
    if (_saving || i < 0 || i >= _bullets.length) return;
    final ac = context.ac;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('delete_bullet_confirm'),
        backgroundColor: ac.bg,
        title: Text(
          'Delete this bullet?',
          style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ac.fg),
        ),
        content: Text(
          'This removes it from your story. You can always add it again later.',
          style: AymaType.sans(size: 13, color: ac.fgMute),
        ),
        actions: [
          TextButton(
            key: const ValueKey('delete_bullet_cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('delete_bullet_confirm_action'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: ac.errorText,
              minimumSize: const Size(64, 48),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _delete(i);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = widget.section;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: ac.bgCard,
        border: Border.all(color: ac.lineSoft),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.title,
            style: AymaType.sans(
              size: 17,
              weight: FontWeight.w600,
              color: ac.fg,
            ),
          ),
          if (s.subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                s.subtitle,
                style: AymaType.sans(size: 12.5, soft: true, color: ac.fgMute),
              ),
            ),
          const SizedBox(height: 8),
          for (var i = 0; i < _bullets.length; i++) _row(ac, i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('add_bullet_${s.pageType}'),
              onPressed: _saving ? null : _startAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(AymaTokens ac, int i) {
    final b = _bullets[i];
    final color = bulletVisibilityColor(ac, b.visibility);
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(bulletVisibilityIcon(b.visibility), size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            bulletVisibilityLabel(b.visibility),
            overflow: TextOverflow.ellipsis,
            style: AymaType.sans(size: 12, color: color),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 10),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_editing == i)
                  TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => unawaited(_commit()),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Add a bullet',
                    ),
                    style: AymaType.sans(size: 15, color: ac.fg),
                  )
                else
                  InkWell(
                    onTap: () => _startEdit(i),
                    child: Text(
                      b.text,
                      style: AymaType.sans(size: 15, color: ac.fg),
                    ),
                  ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    InkWell(
                      key: ValueKey('visibility_${widget.section.pageType}_$i'),
                      // Stays live during a save (Scout NOTE 219 leg a): the
                      // flip is optimistic and _persist serialises the writes.
                      onTap: () => _cycle(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 2,
                        ),
                        child: chip,
                      ),
                    ),
                    if (widget.section.pageId.isNotEmpty &&
                        b.text.trim().isNotEmpty &&
                        _editing != i)
                      InkWell(
                        key: ValueKey('chat_${widget.section.pageType}_$i'),
                        onTap: _saving ? null : () => widget.onChat(b),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.chat_bubble_outline,
                            size: 18,
                            color: ac.fgMute,
                            semanticLabel: 'Ask Ayma about this bullet',
                          ),
                        ),
                      ),
                    InkWell(
                      key: ValueKey('delete_${widget.section.pageType}_$i'),
                      onTap: _saving ? null : () => unawaited(_confirmDelete(i)),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: ac.fgMute,
                          semanticLabel: 'Delete bullet',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
