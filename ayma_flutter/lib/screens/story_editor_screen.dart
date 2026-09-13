import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/private_spans.dart';
import '../util/text_diff.dart';
import '../widgets/ask_ayma_overlay.dart';
import '../widgets/career_timeline_view.dart';
import '../widgets/out_of_credits.dart';
import '../widgets/selectable_markdown.dart';
import '../widgets/story_toolbar.dart';
import 'chat_screen.dart';
import 'story_photos_screen.dart';

/// Your Story — "a living portrait of the person Ayma has come to know."
///
/// One continuous, vertically-scrolling editorial document over the user's
/// wiki sections (title, prose body, visibility, provenance flags all come
/// straight from `GET /story` / `GET /story/ai-notes` — nothing here
/// re-derives that plumbing). Each paragraph is rendered through
/// [SelectableMarkdown] exactly as before: a tap or drag-select on a
/// sentence resolves to an exact raw-body offset range, which is the
/// statement's stable "id" for every action below — public/private
/// persistence, Ask Ayma context, and the live-update flash after Ayma
/// changes it. Nothing here invents a new statement/knowledge model; a
/// "statement" is still exactly what it always was in this codebase: a raw
/// offset range within one wiki page's body.
///
/// Three tabs: Story (everything, colour-neutral — visibility is now an
/// interactive toolbar state, not a permanent badge), Public view (only
/// public statements, previewing what a match would see), and Ayma's Notes
/// (the full, more analytical picture, including anything still AI-only).
class StoryEditorScreen extends StatefulWidget {
  const StoryEditorScreen({super.key, this.api});

  static const path = '/profile/wiki';

  final ApiClient? api;

  @override
  State<StoryEditorScreen> createState() => _StoryEditorScreenState();
}

/// The live text selection inside one section — raw-body offsets, exactly as
/// `SelectableMarkdown` already reports them. This *is* the statement's
/// stable id: no separate `StoryStatement` model was introduced.
class _Sel {
  const _Sel(this.pageId, this.start, this.end, this.text);
  final String pageId;
  final int start;
  final int end;
  final String text;
  bool get active => text.trim().isNotEmpty && end > start;
}

class _StoryEditorScreenState extends State<StoryEditorScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  // 'private' = Story | 'public' = Public view | 'ai' = Ayma's notes. Kept as
  // the same three values the backend/API already used ("Everything" is just
  // relabelled "Story" on screen) rather than inventing a parallel enum.
  String _view = 'private';
  bool _loading = true;
  String? _error;
  List<StorySection> _sections = const [];
  List<StorySection> _aiSections = const [];
  List<AiNotePhoto> _photos = const [];
  bool _busy = false;

  CareerTimeline? _careerTimeline;
  DeepDiveReport? _webFindingsReport;
  String? _webFindingsLoadedFor;

  _Sel _sel = const _Sel('', 0, 0, '');
  final OverlayPortalController _toolbarController = OverlayPortalController();
  Offset? _lastPointerGlobal;
  Offset? _toolbarAnchor;

  // The sentence Ayma most recently changed, briefly flashed in place.
  String? _flashPageId;
  (int, int)? _flashRange;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_loadCareerTimeline());
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
        if (_section(_sel.pageId) == null) _sel = const _Sel('', 0, 0, '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your story ($e).';
        _loading = false;
      });
    }
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

  Future<void> _loadCareerTimeline() async {
    try {
      final t = await _api.careerTimeline();
      if (mounted) setState(() => _careerTimeline = t);
    } catch (e) {
      debugPrint('[story] career timeline failed: $e');
    }
  }

  Future<void> _loadWebFindingsReport(String reportId) async {
    // Guards against a request storm: `_content()` calls this on every build
    // while a web-findings section is visible, so it must be a strict
    // once-per-id fetch, not just an in-flight guard.
    if (reportId.isEmpty || _webFindingsLoadedFor == reportId) return;
    _webFindingsLoadedFor = reportId;
    try {
      final r = await _api.deepDiveReport(reportId);
      if (mounted) setState(() => _webFindingsReport = r);
    } catch (e) {
      debugPrint('[story] web-findings report failed: $e');
    }
  }

  /// Re-fetch the section list after a skill runs / a report finishes.
  Future<void> _refreshStorySections() async {
    try {
      final data = await _api.storyGet();
      if (mounted) setState(() => _sections = data.sections);
    } catch (e) {
      debugPrint('[story] section refresh failed: $e');
    }
  }

  List<StorySection> get _narrativeSections => _sections
      .where((s) => !_reportLinkedPageIds.contains(s.pageId))
      .toList();

  List<StorySection> get _visibleAiSections => _aiSections;

  /// Non-deleted photos — the count the cover stats and the mosaic teaser
  /// both use ("Everything" Ayma actually holds, minus what the user removed).
  List<AiNotePhoto> get _livePhotos =>
      _photos.where((p) => !p.deleted).toList();

  StorySection? get _webFindingsSection {
    for (final s in _sections) {
      if (s.pageId == 'web-findings') return s;
    }
    return null;
  }

  // --- selection -> toolbar ------------------------------------------

  void _onSelect(String pageId, int a, int b, String t) {
    if (b <= a || t.trim().isEmpty) {
      _hideToolbar();
      return;
    }
    setState(() {
      _sel = _Sel(pageId, a, b, t);
      _toolbarAnchor = _lastPointerGlobal ?? _toolbarAnchor;
    });
    _toolbarController.show();
  }

  void _hideToolbar() {
    if (_toolbarController.isShowing) _toolbarController.hide();
    if (_sel.active) setState(() => _sel = const _Sel('', 0, 0, ''));
  }

  Future<void> _applyPrivacy(bool private) async {
    if (!_sel.active || _busy) return;
    final s = _section(_sel.pageId);
    if (s == null) return;
    final sel = _sel;
    _hideToolbar();
    setState(() => _busy = true);
    try {
      final newBody = setPrivacy(s.body, sel.start, sel.end, private);
      await _api.storySaveSection(pageId: s.pageId, body: newBody);
      await _load();
      _toast(private ? 'That passage is now private' : 'That passage is public');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _askAymaForSelection() {
    final sel = _sel;
    // Hide the floating toolbar itself, but — unlike `_hideToolbar()` —
    // deliberately leave `_sel` (and so the sticky sentence highlight) in
    // place: it stays lit behind the Ask Ayma sheet for as long as that
    // sheet is open, and only clears once the sheet is dismissed, below.
    if (_toolbarController.isShowing) _toolbarController.hide();
    if (!sel.active) return;
    final section = _section(sel.pageId);
    unawaited(_openAskAyma(
      pageId: sel.pageId,
      selectedText: sel.text,
      sectionTitle: section?.title ?? '',
    ).whenComplete(() {
      if (!mounted) return;
      if (_sel.pageId == sel.pageId &&
          _sel.start == sel.start &&
          _sel.end == sel.end) {
        setState(() => _sel = const _Sel('', 0, 0, ''));
      }
    }));
  }

  /// Opens the Ask Ayma overlay, then re-syncs the affected section in place
  /// — both quietly during the conversation (`onExchange`) and once more when
  /// the sheet closes — flashing whatever sentence actually changed. This is
  /// the same `/chat` (+ `story_edit` tools) pipeline every other Ayma
  /// conversation uses; no parallel rewrite system.
  Future<void> _openAskAyma({
    required String pageId,
    String selectedText = '',
    String sectionTitle = '',
    String timelineEntryId = '',
    String timelineEntryLabel = '',
  }) async {
    var lastBody = _section(pageId)?.body ?? '';

    Future<void> refresh() async {
      try {
        final data = await _api.storyGet();
        if (!mounted) return;
        setState(() => _sections = data.sections);
        StorySection? updated;
        for (final s in data.sections) {
          if (s.pageId == pageId) updated = s;
        }
        if (updated != null) {
          final range = changedRange(lastBody, updated.body);
          lastBody = updated.body;
          if (range != null) {
            // Show exactly what Ayma changed it to — the same widened,
            // sentence-ish range the visual flash below highlights, so the
            // toast and the flash always agree (one sentence, or several if
            // the edit spanned that far).
            final start = range.$1.clamp(0, updated.body.length);
            final end = range.$2.clamp(0, updated.body.length);
            final changedText = updated.body.substring(start, end).trim();
            if (changedText.isNotEmpty) _toast('Changed to "$changedText"');
            setState(() {
              _flashPageId = pageId;
              _flashRange = range;
            });
            Future.delayed(const Duration(milliseconds: 900), () {
              if (mounted && _flashPageId == pageId) {
                setState(() {
                  _flashPageId = null;
                  _flashRange = null;
                });
              }
            });
          }
        }
      } catch (e) {
        debugPrint('[story] post-chat refresh failed: $e');
      }
      if (pageId == 'career' || timelineEntryId.isNotEmpty) {
        unawaited(_loadCareerTimeline());
      }
    }

    await showAskAymaOverlay(
      context,
      api: _api,
      ctx: AskAymaContext(
        pageId: pageId,
        selectedText: selectedText,
        sectionTitle: sectionTitle,
        timelineEntryId: timelineEntryId,
        timelineEntryLabel: timelineEntryLabel,
      ),
      onExchange: () => unawaited(refresh()),
    );
    await refresh();
    unawaited(_loadAiNotes());
  }

  void _onTapTimelineEntry(TimelineEntry e) {
    final bits = [
      e.org,
      if (e.titleOrDegree.isNotEmpty) e.titleOrDegree,
      if (e.dateRange.isNotEmpty) e.dateRange,
    ];
    unawaited(_openAskAyma(
      pageId: 'career',
      timelineEntryId: e.id,
      timelineEntryLabel: bits.join(' — '),
      sectionTitle: 'Career & Education',
    ));
  }

  Future<void> _addLinkedin() async {
    final controller = TextEditingController();
    final ac = context.ac;
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ac.bg,
        title: Text('Add your LinkedIn', style: AymaType.serif(size: 18, color: ac.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Ayma will read this page directly to help build your career "
              'timeline — nothing is scraped or shared.',
              style: AymaType.sans(size: 13, color: ac.fgMute),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://www.linkedin.com/in/…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.setLinkedinUrl(url);
      _toast('Saved — building your timeline…');
      final refreshed = await _api.refreshCareerTimeline();
      if (mounted) setState(() => _careerTimeline = refreshed);
    } on ApiException catch (e) {
      _toast(e.statusCode == 400
          ? "That doesn't look like a LinkedIn URL."
          : 'Failed ($e)');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showProvenance(StorySection s) async {
    final SectionProvenance prov;
    try {
      prov = await _api.storyProvenance(s.pageId);
    } catch (e) {
      _toast('Could not load ($e)');
      return;
    }
    if (!mounted) return;
    final ac = context.ac;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Why Ayma believes this',
                  style: AymaType.serif(size: 19, color: ac.fg)),
              const SizedBox(height: 14),
              Text(
                prov.conversationCount > 0
                    ? 'Learned across ${prov.conversationCount} '
                        'conversation${prov.conversationCount == 1 ? '' : 's'}.'
                    : "Ayma hasn't traced this to a specific conversation yet.",
                style: AymaType.sans(size: 14, color: ac.fgDim),
              ),
              if (prov.updatedAt != null) ...[
                const SizedBox(height: 4),
                Text('Updated ${_shortDate(prov.updatedAt!)}',
                    style: AymaType.sans(size: 13, color: ac.fgMute)),
              ],
              if (prov.sources.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('SOURCES',
                    style: AymaType.mono(size: 10, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.4)),
                const SizedBox(height: 8),
                for (final src in prov.sources)
                  _ProvenanceSourceRow(
                    source: src,
                    onTap: src.sessionId.isEmpty
                        ? null
                        : () {
                            Navigator.pop(ctx); // dismiss this sheet first
                            _openConversation(src);
                          },
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// "Why Ayma believes this" -> tap a source: land back in the chat near
  /// that conversation. `raw_turns/{sessionId}` is a whole session's worth of
  /// turns, not a single message, so this opens the chat scrolled to (and
  /// briefly highlighting) the first message at/after that source's date —
  /// the closest thing to "open this message" the data model supports.
  Future<void> _openConversation(ProvenanceSource src) async {
    if (!mounted || src.date.isEmpty) return;
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
        child: ChatScreen(apiClient: _api, targetTimestamp: src.date),
      ),
    );
  }

  Future<void> _openHistory(StorySection s) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SectionHistorySheet(
        api: _api,
        section: s,
        onRevert: (versionId) async {
          try {
            await _api.storySectionRevert(pageId: s.pageId, versionId: versionId);
            if (mounted) await _load();
          } catch (e) {
            _toast('Revert failed ($e)');
          }
        },
      ),
    );
  }

  Future<void> _deleteSection(StorySection s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${s.title}?'),
        content: const Text(
          "It comes out of your story. Ayma keeps it in her memory, and you "
          'can bring it back from this section’s history.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await _api.storyRemoveSection(s.pageId);
      await _load();
      _toast('Removed ${s.title}');
    } catch (e) {
      _toast('Failed ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      backgroundColor: ac.bg,
      appBar: AppBar(
        backgroundColor: ac.bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ac.fg,
        title: const SizedBox.shrink(),
      ),
      body: OverlayPortal(
        controller: _toolbarController,
        overlayChildBuilder: (context) => _toolbarAnchor == null
            ? const SizedBox.shrink()
            : StoryToolbar(
                anchor: _toolbarAnchor!,
                isPrivate: isPrivateAt(
                    _section(_sel.pageId)?.body ?? '', _sel.start),
                busy: _busy,
                onMakePublic: () => _applyPrivacy(false),
                onMakePrivate: () => _applyPrivacy(true),
                onAsk: _askAymaForSelection,
                onDismiss: _hideToolbar,
              ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: _StoryTabBar(
                view: _view,
                onChanged: (v) => setState(() {
                  _view = v;
                  _sel = const _Sel('', 0, 0, '');
                }),
              ),
            ),
            Expanded(child: _content()),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final ac = context.ac;
    if (_loading) return const _StorySkeleton();
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

    if (_view == 'ai') return _buildAiNotes();

    final publicView = _view == 'public';
    final rows = publicView
        ? _narrativeSections.where((s) => s.visibility == 'public').toList()
        : _narrativeSections;
    final photos = publicView
        ? _photos.where((p) => p.source == 'profile' && !p.deleted).toList()
        : _livePhotos;

    if (rows.isEmpty && photos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            publicView
                ? 'Nothing is public yet — tap a sentence anywhere in your '
                    'story and choose "Make public".'
                : "Once you and Ayma have talked a little, your story takes "
                    'shape here.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
          ),
        ),
      );
    }

    final anyAiUpdate = !publicView && _sections.any((s) => s.aiUpdatedSinceUser);
    final webFindings = publicView ? null : _webFindingsSection;
    if (webFindings != null && webFindings.reportId != null) {
      unawaited(_loadWebFindingsReport(webFindings.reportId!));
    }

    var num = 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 48),
      children: [
        _StoryCover(
          title: publicView ? 'Public view' : 'Your Story',
          subtitle: publicView
              ? 'What potential matches will see about you.'
              : 'A living portrait, written by Ayma.',
          heroPhotoUrl: publicView ? null : _heroPhotoUrl(),
          topicCount: rows.where((s) => s.body.trim().isNotEmpty).length,
          photoCount: photos.length,
          webFindsCount: _webFindingsReport?.facts.length,
          showLearningBanner: anyAiUpdate,
        ),
        for (var i = 0; i < rows.length; i++) ...[
          if (rows[i].body.trim().isEmpty) const SizedBox.shrink() else ...[
            () { num++; return const SizedBox.shrink(); }(),
            _narrativeSectionWidget(rows[i], num, publicView),
            _sectionDivider(),
          ],
        ],
        if (photos.isNotEmpty) ...[
          _PhotosInterlude(
            number: num + 1,
            photos: photos.take(6).toList(),
            totalCount: photos.length,
            onViewAll: () => context.push(StoryPhotosScreen.path),
          ),
          _sectionDivider(),
        ],
        if (webFindings != null)
          _WebFindingsInterlude(
            number: num + (photos.isNotEmpty ? 2 : 1),
            teaser: _webFindingsTeaser(webFindings.body),
            report: _webFindingsReport,
            reportId: webFindings.reportId,
            onView: webFindings.reportId == null
                ? null
                : () => context.push('/deep-dive/${webFindings.reportId}'),
          ),
      ],
    );
  }

  String? _heroPhotoUrl() {
    for (final p in _photos) {
      if (p.source == 'profile' && !p.deleted) return p.url;
    }
    return null;
  }

  Widget _sectionDivider() {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Divider(height: 0.5, color: ac.lineSoft),
    );
  }

  Widget _narrativeSectionWidget(StorySection s, int number, bool publicView) {
    final flash = _flashPageId == s.pageId ? _flashRange : null;
    final selected = !publicView && _sel.pageId == s.pageId && _sel.active
        ? (_sel.start, _sel.end)
        : null;
    final isCareer = s.pageType == 'career';
    return _NarrativeSection(
      section: s,
      number: number,
      publicView: publicView,
      externalFlash: flash,
      selectedRange: selected,
      onSelect: (a, b, t) {
        if (publicView) return;
        _onSelect(s.pageId, a, b, t);
      },
      onSentenceTap: (a, b, t) {
        if (publicView) return;
        _onSelect(s.pageId, a, b, t);
      },
      onPointerDown: (pos) => _lastPointerGlobal = pos,
      onInfo: publicView ? null : () => _showProvenance(s),
      onHistory: publicView ? null : () => _openHistory(s),
      onRemove: publicView ? null : () => _deleteSection(s),
      trailing: publicView || !isCareer
          ? null
          : _careerTimelineArea(s),
    );
  }

  Widget? _careerTimelineArea(StorySection s) {
    final t = _careerTimeline;
    final ac = context.ac;
    if (t == null) return null;
    if (t.showTimeline && t.entries.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: CareerTimelineView(
          entries: t.entries,
          onTapEntry: _onTapTimelineEntry,
        ),
      );
    }
    if (t.linkedinUrl.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: InkWell(
          onTap: _addLinkedin,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.link, size: 14, color: ac.accent),
            const SizedBox(width: 6),
            Text('Add your LinkedIn to help Ayma build your timeline',
                style: AymaType.sans(size: 12.5, color: ac.accent)),
          ]),
        ),
      );
    }
    return null;
  }

  Widget _buildAiNotes() {
    final ac = context.ac;
    final rows = _visibleAiSections;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            "This fills in as Ayma learns more about you and runs reports — "
            'nothing here yet.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
      children: [
        Text("Ayma's Notes",
            style: AymaType.serif(size: 30, color: ac.fg)),
        const SizedBox(height: 6),
        Text(
          'The intelligence beneath the portrait — everything Ayma has '
          'observed, including what she hasn’t confirmed with you yet.',
          style: AymaType.sans(size: 14, color: ac.fgMute).copyWith(height: 1.5),
        ),
        const SizedBox(height: 28),
        for (var i = 0; i < rows.length; i++) ...[
          _AiNoteSection(
            section: rows[i],
            api: _api,
            onReportUpdated: _refreshStorySections,
            onInfo: () => _showProvenance(rows[i]),
          ),
          if (i != rows.length - 1) _sectionDivider(),
        ],
      ],
    );
  }
}

String _shortDate(String iso) {
  try {
    // Deliberately NOT `.toLocal()` — a provenance date only needs to read as
    // a stable, roughly-right day, not a precisely localised timestamp, and
    // any shift across midnight from the raw UTC value would flip the day
    // depending on the viewer's timezone.
    final d = DateTime.parse(iso);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  } catch (_) {
    return iso;
  }
}

/// One "Why Ayma believes this" source row. Tappable (chevron affordance,
/// matching this app's other tappable list rows — see settings/profile
/// screens) whenever [onTap] is given; otherwise a plain, inert row exactly
/// as before — the graceful fallback for a source with no resolvable
/// conversation (shouldn't happen given the current data model, but never a
/// crash or a dead tap target).
class _ProvenanceSourceRow extends StatelessWidget {
  const _ProvenanceSourceRow({required this.source, this.onTap});

  final ProvenanceSource source;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(Icons.forum_outlined, size: 14, color: ac.fgMute),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Conversation · ${_shortDate(source.date)}',
              style: AymaType.sans(size: 13, color: ac.fgDim)),
        ),
        if (onTap != null)
          Icon(Icons.chevron_right, size: 16, color: ac.fgMute),
      ]),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

// --- tab bar -----------------------------------------------------------

class _StoryTabBar extends StatelessWidget {
  const _StoryTabBar({required this.view, required this.onChanged});
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 9),
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
                size: 12.5,
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
        seg('private', 'Story'),
        seg('public', 'Public view'),
        seg('ai', "Ayma's notes"),
      ]),
    );
  }
}

// --- cover ---------------------------------------------------------------

class _StoryCover extends StatelessWidget {
  const _StoryCover({
    required this.title,
    required this.subtitle,
    required this.heroPhotoUrl,
    required this.topicCount,
    required this.photoCount,
    required this.webFindsCount,
    required this.showLearningBanner,
  });

  final String title;
  final String subtitle;
  final String? heroPhotoUrl;
  final int topicCount;
  final int photoCount;
  final int? webFindsCount;
  final bool showLearningBanner;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AymaType.serif(size: 40, color: ac.fg)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: AymaType.sans(size: 15, color: ac.fgMute).copyWith(height: 1.4)),
          if (heroPhotoUrl != null) ...[
            const SizedBox(height: 22),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.network(heroPhotoUrl!, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(color: ac.bgElev)),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(children: [
            _Stat(label: 'Topics', value: '$topicCount'),
            _Stat(label: 'Photos', value: '$photoCount'),
            if (webFindsCount != null)
              _Stat(label: 'Web finds', value: '$webFindsCount'),
          ]),
          if (showLearningBanner) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: ac.accentFaint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Icon(Icons.auto_awesome, size: 15, color: ac.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Ayma keeps learning about you as you talk.',
                      style: AymaType.sans(size: 12.5, color: ac.accent)),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(right: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: AymaType.serif(size: 22, color: ac.fg)),
          const SizedBox(height: 2),
          Text(label.toUpperCase(),
              style: AymaType.mono(size: 9, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.2)),
        ],
      ),
    );
  }
}

// --- narrative section -----------------------------------------------

class _NarrativeSection extends StatelessWidget {
  const _NarrativeSection({
    required this.section,
    required this.number,
    required this.publicView,
    required this.externalFlash,
    this.selectedRange,
    required this.onSelect,
    required this.onSentenceTap,
    required this.onPointerDown,
    required this.onInfo,
    required this.onHistory,
    required this.onRemove,
    this.trailing,
  });

  final StorySection section;
  final int number;
  final bool publicView;
  final (int, int)? externalFlash;

  /// The currently tapped/selected sentence's raw-body range, kept lit for
  /// as long as the floating toolbar (or the Ask Ayma sheet reached from it)
  /// is open — see `SelectableMarkdown.selectedRange`.
  final (int, int)? selectedRange;
  final void Function(int, int, String) onSelect;
  final void Function(int, int, String) onSentenceTap;
  final ValueChanged<Offset> onPointerDown;
  final VoidCallback? onInfo;
  final VoidCallback? onHistory;
  final VoidCallback? onRemove;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final md = AymaType.serif(size: 17, color: ac.fg).copyWith(height: 1.65);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${number.toString().padLeft(2, '0')}  ${section.title.toUpperCase()}',
          style: AymaType.mono(size: 11, color: ac.accent).copyWith(letterSpacing: 2),
        ),
        const SizedBox(height: 14),
        Listener(
          onPointerDown: (e) => onPointerDown(e.position),
          behavior: HitTestBehavior.translucent,
          child: SelectableMarkdown(
            raw: section.body,
            style: md,
            linkColor: ac.accent,
            privateColor: ac.fgMute,
            publicView: publicView,
            onSelect: publicView ? null : onSelect,
            onSentenceTap: publicView ? null : onSentenceTap,
            externalFlash: externalFlash,
            selectedRange: selectedRange,
          ),
        ),
        if (trailing != null) trailing!,
        if (!publicView && (onInfo != null || onHistory != null || onRemove != null)) ...[
          const SizedBox(height: 14),
          // Wrap, not Row: three footnote links plus separators can exceed a
          // narrow screen's width (or a scaled-up font's), and this reads
          // fine wrapped onto a second line rather than overflowing.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (onInfo != null) _footnote(context, 'Why Ayma believes this', onInfo!),
              if (onInfo != null && onHistory != null) _dot(ac),
              if (onHistory != null) _footnote(context, 'History', onHistory!),
              if (onHistory != null && onRemove != null) _dot(ac),
              if (onRemove != null) _footnote(context, 'Remove', onRemove!),
            ],
          ),
        ],
      ],
    );
  }

  Widget _dot(AymaTokens ac) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text('·', style: AymaType.sans(size: 12, color: ac.fgMute)),
      );

  Widget _footnote(BuildContext context, String label, VoidCallback onTap) {
    final ac = context.ac;
    return InkWell(
      onTap: onTap,
      child: Text(label,
          style: AymaType.mono(size: 9.5, color: ac.fgMute).copyWith(letterSpacing: 0.8)),
    );
  }
}

// --- photos interlude ---------------------------------------------------

class _PhotosInterlude extends StatelessWidget {
  const _PhotosInterlude({
    required this.number,
    required this.photos,
    required this.totalCount,
    required this.onViewAll,
  });

  final int number;
  final List<AiNotePhoto> photos;
  final int totalCount;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final extra = totalCount - photos.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${number.toString().padLeft(2, '0')}  PHOTOS',
            style: AymaType.mono(size: 11, color: ac.accent).copyWith(letterSpacing: 2)),
        const SizedBox(height: 10),
        Text('A few glimpses into my world.',
            style: AymaType.serif(size: 22, color: ac.fg)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < photos.length; i++)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(children: [
                  Image.network(photos[i].url, width: 104, height: 104, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          width: 104, height: 104, color: ac.bgElev)),
                  if (i == photos.length - 1 && extra > 0)
                    Container(
                      width: 104,
                      height: 104,
                      color: Colors.black.withValues(alpha: 0.45),
                      alignment: Alignment.center,
                      child: Text('+$extra',
                          style: AymaType.serif(size: 20, color: Colors.white)),
                    ),
                ]),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('$totalCount photo${totalCount == 1 ? '' : 's'} help Ayma understand your '
            'appearance, style and lifestyle.',
            style: AymaType.sans(size: 12.5, color: ac.fgMute)),
        const SizedBox(height: 10),
        InkWell(
          onTap: onViewAll,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('VIEW ALL PHOTOS',
                style: AymaType.mono(size: 10, color: ac.accent).copyWith(letterSpacing: 1.2)),
            const SizedBox(width: 4),
            Icon(Icons.arrow_forward, size: 12, color: ac.accent),
          ]),
        ),
      ],
    );
  }
}

// --- web findings interlude ---------------------------------------------

class _WebFindingsInterlude extends StatelessWidget {
  const _WebFindingsInterlude({
    required this.number,
    required this.teaser,
    required this.report,
    required this.reportId,
    required this.onView,
  });

  final int number;
  final _SkillTeaser teaser;
  final DeepDiveReport? report;
  final String? reportId;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final facts = report?.facts ?? const [];
    final confirmed = facts.where((f) => f.confidence == 'high').length;
    final needsReview = facts.length - confirmed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${number.toString().padLeft(2, '0')}  BEYOND OUR CONVERSATIONS',
            style: AymaType.mono(size: 11, color: ac.accent).copyWith(letterSpacing: 2)),
        const SizedBox(height: 10),
        Text('What Ayma found online.', style: AymaType.serif(size: 22, color: ac.fg)),
        const SizedBox(height: 12),
        Text(
          'Ayma searched the web to learn more about you. You can review what '
          'was found and decide what to keep private.',
          style: AymaType.sans(size: 14, color: ac.fgDim).copyWith(height: 1.5),
        ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${facts.length} finding${facts.length == 1 ? '' : 's'}',
                  style: AymaType.sans(size: 12.5, weight: FontWeight.w600, color: ac.fg)),
              Text('$confirmed confirmed',
                  style: AymaType.sans(size: 12.5, color: ac.success)),
              if (needsReview > 0)
                Text('$needsReview needs review',
                    style: AymaType.sans(size: 12.5, color: ac.warning)),
            ],
          ),
        ],
        const SizedBox(height: 14),
        if (onView != null)
          InkWell(
            onTap: onView,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('VIEW WEB FINDINGS',
                  style: AymaType.mono(size: 10, color: ac.accent).copyWith(letterSpacing: 1.2)),
              const SizedBox(width: 4),
              Icon(Icons.arrow_forward, size: 12, color: ac.accent),
            ]),
          )
        else
          Text(teaser.headline.isNotEmpty ? teaser.headline : "Ayma hasn't searched yet.",
              style: AymaType.sans(size: 12.5, color: ac.fgMute)),
      ],
    );
  }
}

// --- tasteful loading skeleton -------------------------------------------

class _StorySkeleton extends StatelessWidget {
  const _StorySkeleton();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: ac.bgElev,
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        bar(180, 40),
        bar(260, 16),
        const SizedBox(height: 28),
        bar(220, 12),
        const SizedBox(height: 14),
        bar(double.infinity, 16),
        bar(double.infinity, 16),
        bar(240, 16),
        const SizedBox(height: 28),
        bar(220, 12),
        const SizedBox(height: 14),
        bar(double.infinity, 16),
        bar(double.infinity, 16),
        bar(200, 16),
      ],
    );
  }
}

// --- Ayma's Notes: skill-report cards (kept from the previous design) ---

const _reportLinkedPageIds = {
  'face-analysis',
  'body-analysis',
  'physical-profile',
  'web-findings',
};

String _skillReportPath(String pageId, String reportId) {
  final id = Uri.encodeComponent(reportId);
  return pageId == 'web-findings' ? '/deep-dive/$id' : '/appearance/$id';
}

String _skillCardEyebrow(String pageId) =>
    pageId == 'web-findings' ? "AYMA'S RESEARCH" : "AYMA'S REPORT";

class _SkillTeaser {
  const _SkillTeaser(this.headline, this.detail);
  final String headline;
  final String detail;
}

final _medianScoreRe = RegExp(
  r'Overall:?\s*(-?\d+(?:\.\d+)?)\s*/\s*10\s*\(median across (\d+) reads?\)',
);
final _scoreLineRe = RegExp(
  r'Overall\s*(-?\d+(?:\.\d+)?)\s*/\s*10(?:\s*[—-]\s*([^.\n]+))?\.',
);
final _webConfidenceRe = RegExp(r'Overall confidence:\s*([a-zA-Z]+)\.');

String _capLine(String s, [int max = 160]) {
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max - 1).trim()}…';
}

String _firstLine(String body) {
  for (final line in body.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return _capLine(t, 120);
  }
  return '';
}

_SkillTeaser _scoreTeaser(String body) {
  final median = _medianScoreRe.firstMatch(body);
  final latest = _scoreLineRe.firstMatch(body);
  var headline = '';
  var detail = '';
  if (median != null) {
    final score = median.group(1);
    final n = median.group(2);
    headline = 'Overall $score/10 (median across $n read${n == '1' ? '' : 's'})';
    final verdict = latest?.group(2)?.trim();
    if (verdict != null && verdict.isNotEmpty) detail = verdict;
  } else if (latest != null) {
    final score = latest.group(1);
    final verdict = latest.group(2)?.trim();
    headline = (verdict != null && verdict.isNotEmpty)
        ? 'Overall $score/10 — $verdict'
        : 'Overall $score/10';
    final tailStart = latest.end;
    final blank = body.indexOf('\n\n', tailStart);
    final tail = body.substring(tailStart, blank < 0 ? body.length : blank).trim();
    if (tail.isNotEmpty) detail = _capLine(tail);
  }
  if (headline.isEmpty) headline = _firstLine(body);
  return _SkillTeaser(headline, detail);
}

_SkillTeaser _attributesTeaser(String body) {
  final bullets = body
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.startsWith('- '))
      .map((l) => l.substring(2).trim())
      .toList();
  if (bullets.isEmpty) return _SkillTeaser(_firstLine(body), '');
  final headline = bullets.take(2).join(' · ');
  final rest = bullets.length - 2;
  return _SkillTeaser(headline, rest > 0 ? '+$rest more attribute${rest == 1 ? '' : 's'}' : '');
}

_SkillTeaser _webFindingsTeaser(String body) {
  final conf = _webConfidenceRe.firstMatch(body);
  final headline = conf != null ? 'Overall confidence: ${conf.group(1)}' : _firstLine(body);
  final parts = body.split('\n\n');
  final detail = parts.length > 1 ? _capLine(parts[1]) : '';
  return _SkillTeaser(headline, detail);
}

_SkillTeaser _extractSkillTeaser(String pageId, String body) {
  switch (pageId) {
    case 'face-analysis':
    case 'body-analysis':
      return _scoreTeaser(body);
    case 'physical-profile':
      return _attributesTeaser(body);
    case 'web-findings':
      return _webFindingsTeaser(body);
    default:
      return _SkillTeaser(_firstLine(body), '');
  }
}

/// One section of Ayma's Notes: title, a small provenance action, and either
/// flowing text (an ordinary page still AI-only) or a skill-report teaser
/// card (face/body/physical-profile/web-findings) linking to the existing
/// dedicated report screens.
class _AiNoteSection extends StatefulWidget {
  const _AiNoteSection({
    required this.section,
    required this.api,
    required this.onReportUpdated,
    required this.onInfo,
  });

  final StorySection section;
  final ApiClient api;
  final Future<void> Function() onReportUpdated;
  final VoidCallback onInfo;

  @override
  State<_AiNoteSection> createState() => _AiNoteSectionState();
}

class _AiNoteSectionState extends State<_AiNoteSection> {
  bool _running = false;

  static const _appearancePageIds = {'face-analysis', 'body-analysis', 'physical-profile'};

  Future<void> _runAppearanceNow() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final res = await widget.api.runAppearanceReport();
      if (!mounted) return;
      if (res.usageCapped) {
        showOutOfCreditsSnack(context);
        return;
      }
      await widget.onReportUpdated();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text("Couldn't run that — try again.")));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = widget.section;
    final isAi = s.visibility == 'ai';
    final bodyColor = isAi ? ac.fgDim : ac.fg;
    final isReportLinked = _reportLinkedPageIds.contains(s.pageId) && !s.userEdited;
    final reportId = s.reportId;
    final hasReport = reportId != null && reportId.isNotEmpty;
    final isAppearancePage = _appearancePageIds.contains(s.pageId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(s.title, style: AymaType.serif(size: 19, color: ac.fg))),
          Text(
            s.visibility == 'public' ? 'PUBLIC' : (isAi ? 'AI ONLY' : 'PRIVATE'),
            style: AymaType.mono(size: 9, color: ac.fgMute).copyWith(letterSpacing: 1.2),
          ),
        ]),
        const SizedBox(height: 10),
        if (s.body.trim().isEmpty)
          Text('Nothing here yet.', style: AymaType.sans(size: 13, color: ac.fgMute))
        else if (isReportLinked)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ac.bgElev,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: ac.lineSoft, width: 0.5),
            ),
            child: Builder(builder: (context) {
              final teaser = _extractSkillTeaser(s.pageId, s.body);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_skillCardEyebrow(s.pageId),
                      style: AymaType.mono(size: 10, color: ac.fgMute).copyWith(letterSpacing: 1.4)),
                  if (teaser.headline.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(teaser.headline,
                        style: AymaType.serif(size: 15, color: bodyColor).copyWith(height: 1.4)),
                  ],
                  if (teaser.detail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(teaser.detail, style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
                  ],
                  const SizedBox(height: 10),
                  if (hasReport)
                    InkWell(
                      onTap: () => context.push(_skillReportPath(s.pageId, reportId)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('VIEW FULL REPORT',
                            style: AymaType.mono(size: 10, color: ac.accent).copyWith(letterSpacing: 1.2)),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_forward, size: 12, color: ac.accent),
                      ]),
                    )
                  else
                    Row(children: [
                      Expanded(
                        child: Text("Ayma hasn't finished a full report for this yet.",
                            style: AymaType.sans(size: 12, color: ac.fgMute)),
                      ),
                      if (_running)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else if (isAppearancePage)
                        TextButton(onPressed: _runAppearanceNow, child: const Text('Run it'))
                      else
                        TextButton(
                            onPressed: () => context.push('/skills'),
                            child: const Text('Run it')),
                    ]),
                ],
              );
            }),
          )
        else
          Text(s.body, style: AymaType.sans(size: 14.5, color: bodyColor).copyWith(height: 1.6)),
        const SizedBox(height: 10),
        InkWell(
          onTap: widget.onInfo,
          child: Text('Why Ayma believes this',
              style: AymaType.mono(size: 9.5, color: ac.fgMute).copyWith(letterSpacing: 0.8)),
        ),
      ],
    );
  }
}

// --- per-section history sheet (unchanged) -------------------------------

String relativeTime(int ms) {
  if (ms <= 0) return '';
  final d = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - ms);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}

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
            Text('${section.title} · history', style: AymaType.serif(size: 18, color: ac.fg)),
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
                    separatorBuilder: (_, __) => Divider(height: 0.5, color: ac.lineSoft),
                    itemBuilder: (context, i) {
                      final v = versions[i];
                      final kind = _historyKind(context, v);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(kind.icon, size: 18, color: kind.color),
                        title: Text(v.note.isEmpty ? 'Edited' : v.note,
                            style: AymaType.sans(size: 13, color: ac.fg)),
                        subtitle: Text('${relativeTime(v.createdAtMs)} · ${kind.label}',
                            style: AymaType.sans(size: 11, color: kind.color)),
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

  _HistoryKind _historyKind(BuildContext context, StoryVersion v) {
    final ac = context.ac;
    final note = v.note;
    if (v.author == 'ayma') {
      return _HistoryKind(Icons.auto_awesome, ac.accent, 'Ayma learned this');
    }
    if (note.startsWith('deleted ')) {
      return _HistoryKind(Icons.delete_outline, ac.error, 'removed');
    }
    if (note.startsWith('reverted to ')) {
      return _HistoryKind(Icons.history, ac.accent, 'reverted');
    }
    if (note.startsWith('made ') && (note.endsWith(' public') || note.endsWith(' private'))) {
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed ($e)')));
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
                      : Text(detail.body,
                          style: AymaType.sans(size: 13, color: ac.fg)),
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
