import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in _sections)
          BulletSectionCard(
            key: ValueKey('bullet_section_${s.pageType}'),
            section: s,
            onSave: (bullets) => _save(s, bullets),
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
  });

  final BulletSection section;
  final Future<bool> Function(List<StoryBullet> bullets) onSave;

  @override
  State<BulletSectionCard> createState() => _BulletSectionCardState();
}

class _BulletSectionCardState extends State<BulletSectionCard> {
  late List<StoryBullet> _bullets = List.of(widget.section.bullets);
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  int? _editing;
  bool _saving = false;

  /// An Ayma-only bullet the server already holds: the user can't delete it
  /// (the server would refuse the edit).
  bool _locked(StoryBullet b) => b.isAiOnly && b.id.isNotEmpty;

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
    if (_editing == null && !_saving) _bullets = List.of(widget.section.bullets);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit(int i) {
    if (_saving || _locked(_bullets[i])) return;
    setState(() {
      _editing = i;
      _ctrl.text = _bullets[i].text;
    });
    _focus.requestFocus();
  }

  void _startAdd() {
    if (_saving) return;
    unawaited(_commit());
    setState(() {
      _bullets = [..._bullets, const StoryBullet(text: '', visibility: 'private')];
      _editing = _bullets.length - 1;
      _ctrl.clear();
    });
    _focus.requestFocus();
  }

  /// Finishes the open edit: a multi-sentence text becomes one bullet per
  /// sentence, an emptied text removes the bullet; then saves the section.
  Future<void> _commit() async {
    final i = _editing;
    if (i == null || i >= _bullets.length) return;
    final vis = _bullets[i].visibility;
    final pieces = splitIntoBullets(_ctrl.text);
    final next = [
      ..._bullets.sublist(0, i),
      for (final p in pieces) StoryBullet(text: p, visibility: vis),
      ..._bullets.sublist(i + 1),
    ];
    final unchanged = pieces.length == 1 && pieces.first == _bullets[i].text;
    setState(() {
      _editing = null;
      _bullets = next;
    });
    if (!unchanged) await _persist();
  }

  Future<void> _persist() async {
    setState(() => _saving = true);
    final ok = await widget.onSave(_bullets);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _bullets = List.of(widget.section.bullets);
    });
  }

  void _cycle(int i) {
    if (_saving || _locked(_bullets[i])) return;
    setState(() {
      _bullets[i] = StoryBullet(
        text: _bullets[i].text,
        visibility: nextBulletVisibility(_bullets[i].visibility),
      );
    });
    unawaited(_persist());
  }

  void _delete(int i) {
    if (_saving || _locked(_bullets[i])) return;
    setState(() => _bullets.removeAt(i));
    unawaited(_persist());
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
          Text(s.title, style: AymaType.sans(size: 17, weight: FontWeight.w600, color: ac.fg)),
          if (s.subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(s.subtitle, style: AymaType.sans(size: 12.5, soft: true, color: ac.fgMute)),
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
    final locked = _locked(b);
    final color = bulletVisibilityColor(ac, b.visibility);
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(locked ? Icons.lock : bulletVisibilityIcon(b.visibility), size: 14, color: color),
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
                    onTap: locked ? null : () => _startEdit(i),
                    child: Text(b.text, style: AymaType.sans(size: 15, color: ac.fg)),
                  ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    if (locked)
                      Tooltip(
                        message: 'Only Ayma sees this. It can’t be deleted.',
                        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: chip),
                      )
                    else
                      InkWell(
                        key: ValueKey('visibility_${widget.section.pageType}_$i'),
                        onTap: _saving ? null : () => _cycle(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                          child: chip,
                        ),
                      ),
                    if (!locked)
                      InkWell(
                        key: ValueKey('delete_${widget.section.pageType}_$i'),
                        onTap: _saving ? null : () => _delete(i),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(Icons.delete_outline, size: 18, color: ac.fgMute, semanticLabel: 'Delete bullet'),
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
