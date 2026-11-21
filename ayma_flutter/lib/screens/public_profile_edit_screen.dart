import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/overflow_guards.dart';

/// Edit ONLY the public elements of My public profile (founder order, Nov 19
/// 2026). The pencil on [MyPublicProfileScreen] opens this instead of the full
/// Your Story editor: it lists exactly the public-visibility bullets the public
/// profile renders, grouped the same way (the canonical sections), each editable
/// in place, with an "Add a note" per section that creates a new PUBLIC bullet.
///
/// Private and Ayma-only content never appears here. It still edits the SAME
/// underlying graph nodes (via `GET/PUT /profile/bullets` — bullet id == node
/// id), no copies: on save each section's private bullets are re-sent unchanged
/// (a section PUT replaces the whole section, so dropping them would delete
/// them), and the server re-attaches the Ayma-only bullets it preserves itself.
class PublicProfileEditScreen extends StatefulWidget {
  const PublicProfileEditScreen({super.key, this.api});

  static const path = '/profile/me/public/edit';

  /// Injectable for tests; production builds its own [ApiClient].
  final ApiClient? api;

  @override
  State<PublicProfileEditScreen> createState() =>
      _PublicProfileEditScreenState();
}

class _PublicProfileEditScreenState extends State<PublicProfileEditScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<List<_EditSection>> _future = _load();
  List<_EditSection> _sections = const [];
  bool _saving = false;
  bool _dirty = false;
  bool _savedAny = false; // a save happened → the caller refreshes the profile

  Future<List<_EditSection>> _load() async {
    // `profileBullets` returns the canonical sections with public + private
    // bullets (Ayma-only is stripped server-side). We keep only the sections
    // that have at least one PUBLIC bullet, in the order the profile renders
    // them (profileBullets is pre-sorted by section order).
    final raw = await withColdStartRetry(() => _api.profileBullets());
    final sections = <_EditSection>[];
    for (final s in raw) {
      if (s.bullets.any((b) => b.visibility == 'public')) {
        sections.add(_EditSection.fromBulletSection(s));
      }
    }
    _sections = sections;
    return sections;
  }

  @override
  void dispose() {
    for (final s in _sections) {
      s.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      var wrote = false;
      for (final section in _sections) {
        final composed = section.compose();
        if (!section.matchesOriginal(composed)) {
          await _api.profileBulletsSave(section.pageId, composed);
          section.commit(composed);
          wrote = true;
        }
      }
      if (!mounted) return;
      _savedAny = _savedAny || wrote;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      AymaToast.show(
        context,
        wrote ? 'Saved to your public profile.' : 'No changes to save.',
        kind: AymaToastKind.success,
      );
      // Leave with a direct pop, NOT maybePop: _dirty was just cleared, but the
      // PopScope in the live tree still carries canPop:false from the last build
      // (setState only SCHEDULES the rebuild), so maybePop would re-run the
      // discard path and strand the user on the edit screen after a good save
      // (NOTE 279 defect 1). A direct pop bypasses PopScope.canPop.
      if (wrote) Navigator.of(context).pop(_savedAny);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AymaToast.show(
        context,
        "Couldn't save your changes. Try again.",
        kind: AymaToastKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (!leave || !context.mounted) return;
        Navigator.of(context).pop(_savedAny);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: const AymaBackButton(),
          title: const Text('Edit public profile'),
          actions: [
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              TextButton(
                key: const ValueKey('publicEditSave'),
                onPressed: _dirty ? _save : null,
                child: const Text('Save'),
              ),
          ],
        ),
        body: FutureBuilder<List<_EditSection>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _Message(
                text: "Couldn't load your public profile.",
                action: ('Retry', () => setState(() => _future = _load())),
              );
            }
            final sections = snap.data ?? const [];
            if (sections.isEmpty) {
              return const _Message(
                text:
                    'Nothing public yet. Make a note public from Your Story and '
                    'it shows up here to edit.',
              );
            }
            return CenteredScroll(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final section in sections) ...[
                    _SectionView(
                      section: section,
                      onChanged: _markDirty,
                    ),
                    Divider(height: 32, color: ac.lineSoft),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your unsaved edits to your public profile will '
            'be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// One canonical section's editable state: the retained private bullets (hidden
/// but re-sent on save) and the editable public bullets, in the profile's order.
class _EditSection {
  _EditSection({
    required this.pageId,
    required this.title,
    required this.original,
    required this.drafts,
  });

  factory _EditSection.fromBulletSection(BulletSection s) {
    final drafts = <_PublicDraft>[];
    for (final b in s.bullets) {
      if (b.visibility == 'public') {
        drafts.add(_PublicDraft(
          id: b.id,
          imageUrl: b.imageUrl,
          controller: TextEditingController(text: b.text),
        ));
      }
    }
    return _EditSection(
      pageId: s.pageId,
      title: s.title,
      original: List.unmodifiable(s.bullets),
      drafts: drafts,
    );
  }

  final String pageId;
  final String title;

  /// The full original bullet list (public + private), used to preserve order
  /// and to re-send private bullets unchanged on save.
  List<StoryBullet> original;

  /// Editable public bullets, in order. A draft with an empty id is a new note.
  final List<_PublicDraft> drafts;

  void addNote() => drafts.add(_PublicDraft(
        id: '',
        imageUrl: '',
        controller: TextEditingController(),
      ));

  void removeDraft(_PublicDraft d) {
    drafts.remove(d);
    d.controller.dispose();
  }

  /// Ids of public bullets the user X'd — made PRIVATE on save (the node is
  /// retained with its content and re-sent `visibility: private`, never
  /// deleted). It leaves the public profile render and stays in Your Story.
  /// Deletion is only the explicit Delete action in the item bubble (founder
  /// Nov 20).
  final Set<String> _madePrivateIds = {};

  /// X on a public item → make it private. An EXISTING bullet is marked private
  /// (kept, re-sent private on save); a brand-new unsaved note is just discarded
  /// (nothing was ever public to retain).
  void makePrivate(_PublicDraft d) {
    if (d.id.isNotEmpty) _madePrivateIds.add(d.id);
    removeDraft(d);
  }

  /// The save payload: original order preserved, each public bullet's text taken
  /// from its (non-empty) draft, private bullets re-sent as-is, new notes
  /// appended. Empty public text drops that bullet (an in-place delete).
  List<StoryBullet> compose() {
    final out = <StoryBullet>[];
    final byId = {
      for (final d in drafts)
        if (d.id.isNotEmpty) d.id: d,
    };
    for (final b in original) {
      if (b.visibility == 'public') {
        if (_madePrivateIds.contains(b.id)) {
          // X'd → make private: keep the node, re-send it PRIVATE (leaves the
          // public render, stays in Your Story). Never a delete.
          out.add(StoryBullet(
              id: b.id,
              text: b.text,
              visibility: 'private',
              imageUrl: b.imageUrl));
          continue;
        }
        final d = byId[b.id];
        final text = d?.controller.text.trim() ?? '';
        if (d == null || text.isEmpty) continue; // cleared → in-place delete
        out.add(StoryBullet(
            id: b.id, text: text, visibility: 'public', imageUrl: b.imageUrl));
      } else {
        out.add(b); // private retained verbatim
      }
    }
    for (final d in drafts) {
      if (d.id.isEmpty) {
        final text = d.controller.text.trim();
        if (text.isNotEmpty) {
          out.add(StoryBullet(id: '', text: text, visibility: 'public'));
        }
      }
    }
    return out;
  }

  /// True when [composed] is identical to what is already stored, so an
  /// untouched section is never written (no needless `updated_at` bump).
  bool matchesOriginal(List<StoryBullet> composed) {
    if (composed.length != original.length) return false;
    for (var i = 0; i < composed.length; i++) {
      final a = composed[i];
      final b = original[i];
      if (a.id != b.id ||
          a.text != b.text ||
          a.visibility != b.visibility ||
          a.imageUrl != b.imageUrl) {
        return false;
      }
    }
    return true;
  }

  /// After a successful save, adopt the composed list as the new baseline so a
  /// second Save tap is a no-op until the next edit.
  void commit(List<StoryBullet> composed) {
    original = List.unmodifiable(composed);
  }

  void dispose() {
    for (final d in drafts) {
      d.controller.dispose();
    }
  }
}

class _PublicDraft {
  _PublicDraft({
    required this.id,
    required this.imageUrl,
    required this.controller,
  }) : _lastText = controller.text;

  final String id;
  final String imageUrl;
  final TextEditingController controller;

  String _lastText;
  VoidCallback? _listener;

  /// Fire [onEdit] whenever this bullet's text changes — including a
  /// PROGRAMMATIC change (an accessibility `ACTION_SET_TEXT`/`set_text`) that
  /// never triggers `TextField.onChanged`, so Save arms on every edit, not only
  /// on an IME keystroke (NOTE 279 defect 1). Selection-only notifications are
  /// ignored by comparing the text itself.
  void wire(VoidCallback onEdit) {
    if (_listener != null) return;
    void listener() {
      if (controller.text == _lastText) return;
      _lastText = controller.text;
      onEdit();
    }

    _listener = listener;
    controller.addListener(listener);
  }

  void unwire() {
    final l = _listener;
    if (l != null) {
      controller.removeListener(l);
      _listener = null;
    }
  }
}

class _SectionView extends StatefulWidget {
  const _SectionView({required this.section, required this.onChanged});

  final _EditSection section;
  final VoidCallback onChanged;

  @override
  State<_SectionView> createState() => _SectionViewState();
}

class _SectionViewState extends State<_SectionView> {
  @override
  void initState() {
    super.initState();
    for (final d in widget.section.drafts) {
      d.wire(widget.onChanged);
    }
  }

  @override
  void dispose() {
    for (final d in widget.section.drafts) {
      d.unwire();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final section = widget.section;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            section.title,
            style: AymaType.sans(
                size: 13, weight: FontWeight.w700, color: ac.fgMute),
          ),
        ),
        for (final draft in section.drafts)
          Padding(
            key: ValueKey('bullet_${identityHashCode(draft)}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (draft.imageUrl.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: AymaPhoto(url: draft.imageUrl, displayWidth: 44),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: TextField(
                    controller: draft.controller,
                    minLines: 1,
                    maxLines: null,
                    // Dirty-tracking is driven by a controller listener
                    // (draft.wire), which also catches programmatic set_text —
                    // TextField.onChanged would miss that (NOTE 279 defect 1).
                    textCapitalization: TextCapitalization.sentences,
                    style: AymaType.sans(size: 15, color: ac.fg),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Write something public…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: ac.lineSoft),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: ac.lineSoft),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Make private',
                  icon: Icon(Icons.close, size: 18, color: ac.fgMute),
                  onPressed: () {
                    draft.unwire();
                    // X makes the item PRIVATE (retained in Your Story), not a
                    // delete — deletion is the item bubble's Delete action
                    // (founder Nov 20).
                    setState(() => section.makePrivate(draft));
                    widget.onChanged();
                  },
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('addNote_${section.pageId}'),
            onPressed: () {
              setState(section.addNote);
              section.drafts.last.wire(widget.onChanged);
              widget.onChanged();
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a note'),
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});

  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, color: ac.fgMute),
            ),
            if (action != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ],
        ),
      ),
    );
  }
}
