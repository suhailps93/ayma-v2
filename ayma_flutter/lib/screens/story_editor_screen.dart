import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../util/text_diff.dart';
import '../widgets/ask_ayma_overlay.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/career_timeline_view.dart';
import '../widgets/living_report_view.dart';
import '../widgets/out_of_credits.dart';
import '../widgets/photo_gallery.dart';
import 'chat_screen.dart';

/// Your Story — "a living portrait of the person Ayma has come to know."
///
/// The narrative passages themselves (title, prose body, visibility) are now
/// rendered through the ONE shared [LivingReportView] renderer (§ generic
/// reports), embedded here — `shrinkWrap`/`showTitle: false` — alongside
/// content the block model doesn't (yet) represent: cover stats, the photo
/// gallery, the merged Appearance card, "Beyond our conversations" (web
/// findings), and the Career & Education timeline. See this file's own
/// top-of-class comment history / the founder's Living-Report-migration
/// report for exactly what's covered by blocks today and what's still
/// bespoke chrome.
///
/// Three tabs: Story (`story_private` — everything, colour-neutral —
/// visibility is now an interactive toolbar state, not a permanent badge),
/// Public view (`story_public` — only public statements, previewing what a
/// match would see), and Ayma's Notes (`story_ai_notes` — the full, more
/// analytical picture, including anything still AI-only).
///
/// See the GUARDRAIL in `living_report_view.dart`'s own file doc: the
/// bespoke content listed above (cover stats, photo gallery, merged
/// Appearance card, web findings, career timeline) stays bespoke only
/// because none of it is block-modeled yet — it must not re-implement
/// anything the narrative blocks below it already render, and any of it
/// that DOES get a block type later should move onto the shared renderer
/// instead of staying bespoke.
class StoryEditorScreen extends StatefulWidget {
  const StoryEditorScreen({super.key, this.api, this.myUid});

  static const path = '/profile/wiki';

  final ApiClient? api;

  /// Injectable for tests; production reads the signed-in Firebase uid —
  /// this screen is always "my own" Story (there's no route param for
  /// viewing someone else's), so [LivingReportView]'s `reportId` is always
  /// the caller's own uid, mirroring `AppearanceReportScreen`/
  /// `MyPublicProfileScreen`.
  final String? myUid;

  @override
  State<StoryEditorScreen> createState() => _StoryEditorScreenState();
}

class _StoryEditorScreenState extends State<StoryEditorScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  String? _liveUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      // No Firebase app configured — never crash the whole screen over it.
      return null;
    }
  }

  String get _uid => widget.myUid ?? _liveUid() ?? '';

  /// Bumped whenever chrome outside the Living Report changes in a way that
  /// might also affect the report's own content (e.g. an Appearance report
  /// run updates `physical_attributes`, which `story_public`'s Attributes
  /// section reads) — folded into the widget's key so it's recreated (and so
  /// refetches) rather than silently going stale.
  int _reportGen = 0;

  // 'private' = Story | 'public' = Public view | 'ai' = Ayma's notes. Kept as
  // the same three values the backend/API already used ("Everything" is just
  // relabelled "Story" on screen) rather than inventing a parallel enum.
  String _view = 'private';
  bool _loading = true;
  String? _error;
  List<StorySection> _sections = const [];
  List<StorySection> _aiSections = const [];
  List<AiNotePhoto> _photos = const [];

  CareerTimeline? _careerTimeline;
  DeepDiveReport? _webFindingsReport;
  String? _webFindingsLoadedFor;

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

  // --- photos ---------------------------------------------------------

  Future<void> _openPhotoDetail(AiNotePhoto p) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => PhotoDetailSheet(
        photo: p,
        onHide: () => _hidePhoto(p),
        onPublish: () => _publishPhoto(p),
        onChat: () => _openChatForPhoto(p),
      ),
    );
  }

  Future<void> _hidePhoto(AiNotePhoto p) async {
    await _api.photoHide(p.url, source: p.source);
    await _loadPhotos();
    _toast('Removed that photo');
  }

  Future<void> _publishPhoto(AiNotePhoto p) async {
    await _api.photoPublish(p.url, source: p.source);
    await _loadPhotos();
    _toast('Added to your public profile');
  }

  Future<void> _openChatForPhoto(AiNotePhoto p) async {
    if (!mounted) return;
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
        child: ChatScreen(apiClient: _api, photoUrl: p.url, photoSource: p.source),
      ),
    );
    if (mounted) await _loadPhotos();
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
    final data = await _api.storyGet();
    final notes = await _api.storyAiNotes();
    if (!mounted) return;
    setState(() {
      _sections = data.sections;
      _aiSections = notes;
      _reportGen++;
    });
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

  /// Same lookup against `_aiSections` — Ayma's Notes tab shows its own web
  /// findings interlude too (§ Living Report migration: previously an inline
  /// skill-card special-case inside the now-removed `_AiNoteSection`; now the
  /// same bespoke `_WebFindingsInterlude` every tab uses).
  StorySection? get _webFindingsAiSection {
    for (final s in _aiSections) {
      if (s.pageId == 'web-findings') return s;
    }
    return null;
  }

  /// Opens the Ask Ayma overlay for a career-timeline entry (the ONE
  /// remaining caller — § Living Report migration: ordinary narrative
  /// passages now go through [LivingReportView]'s own block tap-to-correct
  /// instead of this raw `pageId`/`timelineEntryId`-scoped path, which the
  /// generic report model doesn't represent at all — see `AskAymaContext`'s
  /// own doc on `timelineEntryId` mapping to `story_timeline_entry_id`, a
  /// field with no block-model equivalent). Re-syncs the affected page in
  /// place afterwards and — when the edit actually changed its text — shows
  /// a "Changed to" toast; the same `/chat` (+ `story_edit` tools) pipeline
  /// every other Ayma conversation uses, no parallel rewrite system.
  Future<void> _openAskAyma({
    required String pageId,
    String timelineEntryId = '',
    String timelineEntryLabel = '',
    String sectionTitle = '',
  }) async {
    var lastBody = _section(pageId)?.editableBody ?? '';

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
          final range = changedRange(lastBody, updated.editableBody);
          lastBody = updated.editableBody;
          if (range != null) {
            final start = range.$1.clamp(0, updated.editableBody.length);
            final end = range.$2.clamp(0, updated.editableBody.length);
            final changedText = updated.editableBody.substring(start, end).replaceAll(RegExp(r'\{\{/?(?:private|ai_only)\}\}'), '').trim();
            if (changedText.isNotEmpty) _toast('Changed to "$changedText"');
          }
        }
      } catch (e) {
        debugPrint('[story] post-chat refresh failed: $e');
      }
      unawaited(_loadCareerTimeline());
    }

    await showAskAymaOverlay(
      context,
      api: _api,
      ctx: AskAymaContext(
        pageId: pageId,
        sectionTitle: sectionTitle,
        timelineEntryId: timelineEntryId,
        timelineEntryLabel: timelineEntryLabel,
        quoteTitle: 'Selected text',
        quoteText: timelineEntryLabel,
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: _StoryTabBar(
              view: _view,
              onChanged: (v) => setState(() => _view = v),
            ),
          ),
          Expanded(child: _content()),
        ],
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
    // Public view: only profile-sourced photos — no chat/web ("private")
    // photos and never a deleted group. Story view: every non-deleted photo,
    // any source, but still never deleted (deleted only ever shows in Ayma's
    // notes — see `_buildAiNotes`).
    final photos = publicView
        ? _photos.where((p) => p.source == 'profile' && !p.deleted).toList()
        : _livePhotos;
    final photoGroupsForView = publicView
        ? photoGroups.where((g) => g.$1 == 'profile').toList()
        : photoGroups.where((g) => g.$1 != 'deleted').toList();

    // The merged face/body/physical-profile card belongs in the Story tab
    // like any other private/public content — hidden in Public view unless
    // every source page is explicitly public and has no private passages.
    // The owner-only full report and provenance stay out of Public view.
    final appearanceMerge = _mergeAppearance(_sections);
    final showAppearance = appearanceMerge != null &&
        appearanceMerge.visibility != 'ai' &&
        (!publicView || (appearanceMerge.visibility == 'public' &&
            !appearanceMerge.parts.any((p) => p.section.body.contains('{{private}}'))));

    if (rows.isEmpty && photos.isEmpty && !showAppearance) {
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
    final showCareer = !publicView && _showCareer;
    final reportType = publicView ? 'story_public' : 'story_private';

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
          webFindsCount: publicView ? null : _webFindingsReport?.facts.length,
          showLearningBanner: anyAiUpdate,
        ),
        if (photos.isNotEmpty) ...[
          () { num++; return const SizedBox.shrink(); }(),
          _PhotosSection(
            number: num,
            photos: photos,
            groups: photoGroupsForView,
            onOpen: _openPhotoDetail,
          ),
          _sectionDivider(),
        ],
        // Every narrative wiki page (minus the four report-linked ones —
        // face-analysis/body-analysis/physical-profile/web-findings — which
        // keep their own bespoke cards below, same as before) — the ONE
        // shared Living Report renderer, embedded (§ generic reports): tap
        // tiers, ad-hoc multi-select and the make-public/make-private/delete
        // quick actions all come from here now, superseding the old
        // per-sentence drag-select -> "Edit with Ayma" mechanism.
        if (rows.isNotEmpty) ...[
          LivingReportView(
            key: ValueKey('$reportType:$_reportGen'),
            reportType: reportType,
            reportId: _uid,
            apiClient: _api,
            shrinkWrap: true,
            showTitle: false,
          ),
          _sectionDivider(),
        ],
        if (showCareer) ...[
          () { num++; return const SizedBox.shrink(); }(),
          _careerSection(num),
          _sectionDivider(),
        ],
        if (showAppearance) ...[
          () { num++; return const SizedBox.shrink(); }(),
          _AppearanceCard(
            number: num,
            publicView: publicView,
            merge: appearanceMerge,
            api: _api,
            onReportUpdated: _refreshStorySections,
            onInfo: () => _showProvenance(appearanceMerge.provenanceSection),
          ),
          _sectionDivider(),
        ],
        if (webFindings != null)
          _WebFindingsInterlude(
            number: num + 1,
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

  /// Whether the standalone Career & Education section (below) has anything
  /// to show: a real parsed timeline, or (when there isn't yet) the "Add
  /// your LinkedIn" nudge. Mirrors the old inline `_careerTimelineArea`'s own
  /// null-return conditions exactly, just decoupled from any particular
  /// narrative wiki page's presence — a structured
  /// [CareerTimeline]/[TimelineEntry] concept in its own right (`GET
  /// /story/career-timeline`), not something the block model represents.
  bool get _showCareer {
    final t = _careerTimeline;
    if (t == null) return false;
    if (t.showTimeline && t.entries.isNotEmpty) return true;
    return t.linkedinUrl.isEmpty;
  }

  /// The structured career timeline / "Add your LinkedIn" nudge, standalone
  /// (§ Living Report migration — previously nested as `trailing` under the
  /// narrative "career" wiki page's own section; the page's own prose is now
  /// rendered by [LivingReportView] above like any other narrative section,
  /// and this stays a separate bespoke card below it, not yet represented by
  /// any block type). Call only when [_showCareer] is true.
  Widget _careerSection(int number) {
    final t = _careerTimeline!;
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${number.toString().padLeft(2, '0')}  CAREER & EDUCATION',
            style: AymaType.mono(size: 11, color: ac.accent).copyWith(letterSpacing: 2)),
        const SizedBox(height: 14),
        if (t.showTimeline && t.entries.isNotEmpty)
          CareerTimelineView(entries: t.entries, onTapEntry: _onTapTimelineEntry)
        else
          InkWell(
            onTap: _addLinkedin,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.link, size: 14, color: ac.accent),
              const SizedBox(width: 6),
              Text('Add your LinkedIn to help Ayma build your timeline',
                  style: AymaType.sans(size: 12.5, color: ac.accent)),
            ]),
          ),
      ],
    );
  }

  Widget _buildAiNotes() {
    final ac = context.ac;
    final rows = _visibleAiSections;
    final hasPhotos = _photos.isNotEmpty;
    // Collapse the face/body/physical-profile trio into a single merged card
    // — one card, not three, for what is genuinely one report. Same for
    // web-findings: its own bespoke interlude, not a plain narrative block
    // (see the module-level comment on `_reportLinkedPageIds`).
    final appearanceMerge = _mergeAppearance(rows);
    final webFindings = _webFindingsAiSection;
    if (webFindings != null && webFindings.reportId != null) {
      unawaited(_loadWebFindingsReport(webFindings.reportId!));
    }
    final narrativeRows =
        rows.where((s) => !_reportLinkedPageIds.contains(s.pageId)).toList();

    if (rows.isEmpty && !hasPhotos) {
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
    final hasTrailingChrome = narrativeRows.isNotEmpty ||
        appearanceMerge != null ||
        webFindings != null;
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
        // The only tab that ever shows the "deleted by you" group — every
        // group, deleted included, so the user can see (and if they want,
        // resurrect the context around) anything Ayma still remembers.
        if (hasPhotos) ...[
          Text('Photos', style: AymaType.serif(size: 19, color: ac.fg)),
          const SizedBox(height: 12),
          _PhotoGroupsList(photos: _photos, groups: photoGroups, onOpen: _openPhotoDetail),
          if (hasTrailingChrome) _sectionDivider(),
        ],
        if (narrativeRows.isNotEmpty) ...[
          LivingReportView(
            key: ValueKey('story_ai_notes:$_reportGen'),
            reportType: 'story_ai_notes',
            reportId: _uid,
            apiClient: _api,
            shrinkWrap: true,
            showTitle: false,
          ),
          if (appearanceMerge != null || webFindings != null) _sectionDivider(),
        ],
        if (appearanceMerge != null) ...[
          _AppearanceCard(
            merge: appearanceMerge,
            api: _api,
            onReportUpdated: _refreshStorySections,
            onInfo: () => _showProvenance(appearanceMerge.provenanceSection),
          ),
          if (webFindings != null) _sectionDivider(),
        ],
        if (webFindings != null)
          _WebFindingsInterlude(
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
                color: on ? ac.onAccent : ac.fgDim,
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
                child: AymaPhoto(
                  url: heroPhotoUrl!,
                  displayWidth: 600,
                  error: Container(color: ac.bgElev),
                ),
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

// --- photos section ------------------------------------------------------
//
// The categorized photo breakdown lives inline in the document itself (no
// separate "view all photos" screen — see the removed `story_photos_screen
// .dart`). `photoGroups`/`displayGroup`/`PhotoGallery`/`PhotoDetailSheet`/
// `PhotoViewer` are shared from `widgets/photo_gallery.dart`. Which groups
// render is decided by the caller (`_content()` / `_buildAiNotes()`) per
// tab: Story shows profile/chat/web (never deleted), Public view shows only
// profile, and Ayma's notes is the only tab that ever shows the deleted
// group.

/// The numbered "01 PHOTOS" section used in the Story / Public view document.
class _PhotosSection extends StatelessWidget {
  const _PhotosSection({
    required this.number,
    required this.photos,
    required this.groups,
    required this.onOpen,
  });

  final int number;
  final List<AiNotePhoto> photos;
  final List<(String, String)> groups;
  final void Function(AiNotePhoto) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${number.toString().padLeft(2, '0')}  PHOTOS',
            style: AymaType.mono(size: 11, color: ac.accent).copyWith(letterSpacing: 2)),
        const SizedBox(height: 10),
        Text('A few glimpses into my world.',
            style: AymaType.serif(size: 22, color: ac.fg)),
        const SizedBox(height: 8),
        Text(
          '${photos.length} photo${photos.length == 1 ? '' : 's'} help Ayma understand your '
          'appearance, style and lifestyle.',
          style: AymaType.sans(size: 12.5, color: ac.fgMute),
        ),
        const SizedBox(height: 18),
        _PhotoGroupsList(photos: photos, groups: groups, onOpen: onOpen),
      ],
    );
  }
}

/// The grouped thumbnail grids themselves — one labeled header + [PhotoGallery]
/// per non-empty group, in [groups] order. Shared between the numbered Story
/// document section above and Ayma's notes' own (unnumbered) Photos block.
class _PhotoGroupsList extends StatelessWidget {
  const _PhotoGroupsList({
    required this.photos,
    required this.groups,
    required this.onOpen,
  });

  final List<AiNotePhoto> photos;
  final List<(String, String)> groups;
  final void Function(AiNotePhoto) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (group, label) in groups)
          if (photos.any((p) => displayGroup(p) == group)) ...[
            Text(
              '$label (${photos.where((p) => displayGroup(p) == group).length})',
              style: AymaType.mono(size: 10, color: ac.fgMute).copyWith(letterSpacing: 1.4),
            ),
            const SizedBox(height: 10),
            PhotoGallery(
              photos: photos.where((p) => displayGroup(p) == group).toList(),
              onOpen: onOpen,
            ),
            const SizedBox(height: 20),
          ],
      ],
    );
  }
}

// --- web findings interlude ---------------------------------------------

class _WebFindingsInterlude extends StatelessWidget {
  const _WebFindingsInterlude({
    this.number,
    required this.teaser,
    required this.report,
    required this.reportId,
    required this.onView,
  });

  /// Null in Ayma's Notes (§ `_AppearanceCard`'s own `number` doc: the same
  /// numbered-eyebrow-vs-plain-header split, for the same reason — Story's
  /// numbered document convention doesn't apply there).
  final int? number;
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
    final header = number != null
        ? '${number!.toString().padLeft(2, '0')}  BEYOND OUR CONVERSATIONS'
        : 'BEYOND OUR CONVERSATIONS';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(header,
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

/// The three wiki pages that are really just one appearance report, three
/// times over (`appearance.py`: their `report_id`s all point at the same
/// `users/{uid}/appearance/current` doc). Kept distinct from `web-findings`,
/// which stays its own separate card/eyebrow/link.
const _appearancePageIds = {'face-analysis', 'body-analysis', 'physical-profile'};

/// Fixed display order + short sub-labels for the merged Appearance card.
const _appearancePageOrder = [
  ('face-analysis', 'FACE'),
  ('body-analysis', 'PHYSIQUE'),
  ('physical-profile', 'PROFILE'),
];

/// One of face-analysis / body-analysis / physical-profile that actually has
/// a sub-teaser to show, in fixed display order.
class _AppearancePart {
  const _AppearancePart(this.label, this.section);
  final String label;
  final StorySection section;
}

/// The merged view of the appearance trio, built from whichever of the three
/// pages are present in a given section list (`_sections` for the Story tab,
/// `_aiSections` for Ayma's notes — the two never mix). Null when none of the
/// three pages are present at all.
class _AppearanceMerge {
  const _AppearanceMerge({
    required this.parts,
    required this.reportId,
    required this.visibility,
    required this.provenanceSection,
  });

  /// Only the pages with a non-empty body — same per-part omission the old
  /// per-page cards did with `if (s.body.trim().isEmpty)`.
  final List<_AppearancePart> parts;

  /// The one report id all three pages should share; the first non-empty one
  /// found, in display order, so a stale/empty id on one page never blocks
  /// the single "VIEW FULL REPORT" link.
  final String? reportId;

  /// Most restrictive of the present pages' visibility: `ai` (AI-only, not
  /// even in the Story tab) is more restrictive than `private`, which is
  /// more restrictive than `public`. Defensive — the three should normally
  /// agree — never a crash, never a guess towards `public`.
  final String visibility;

  /// Whichever of the three pages to hand `_showProvenance` — first present
  /// in display order (face-analysis preferred). The three pages likely
  /// share similar provenance; `story.get_section_provenance` is page-scoped
  /// so there's no single "correct" one to pick.
  final StorySection provenanceSection;

  bool get hasReport => reportId != null && reportId!.isNotEmpty;
}

int _visibilityRank(String v) => v == 'public' ? 2 : (v == 'private' ? 1 : 0);

_AppearanceMerge? _mergeAppearance(List<StorySection> sections) {
  final byId = <String, StorySection>{};
  for (final s in sections) {
    if (_appearancePageIds.contains(s.pageId)) byId[s.pageId] = s;
  }
  if (byId.isEmpty) return null;

  final present = [
    for (final (id, _) in _appearancePageOrder) if (byId[id] != null) byId[id]!,
  ];

  String? reportId;
  for (final s in present) {
    final r = s.reportId?.trim();
    if (r != null && r.isNotEmpty) {
      reportId = r;
      break;
    }
  }

  var visibility = present.first.visibility;
  for (final s in present) {
    if (_visibilityRank(s.visibility) < _visibilityRank(visibility)) {
      visibility = s.visibility;
    }
  }

  return _AppearanceMerge(
    parts: [
      for (final (id, label) in _appearancePageOrder)
        if (byId[id] != null && byId[id]!.body.trim().isNotEmpty)
          _AppearancePart(label, byId[id]!),
    ],
    reportId: reportId,
    visibility: _visibilityRank(visibility) == 0 ? 'ai' : visibility,
    provenanceSection: present.first,
  );
}

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

/// The merged Appearance card — face-analysis + body-analysis +
/// physical-profile collapsed into one visual unit, since all three share the
/// exact same underlying report (see `appearance.py`). One widget, driven by
/// [_AppearanceMerge], used both inline in the Story tab (numbered, like
/// `_WebFindingsInterlude`) and in Ayma's Notes (title + visibility tag, like
/// `_AiNoteSection`) — so the two tabs can never drift apart on what "the"
/// appearance report looks like.
class _AppearanceCard extends StatefulWidget {
  const _AppearanceCard({
    required this.merge,
    required this.api,
    required this.onReportUpdated,
    required this.onInfo,
    this.number,
    this.publicView = false,
  });

  final bool publicView;
  final _AppearanceMerge merge;
  final ApiClient api;
  final Future<void> Function() onReportUpdated;
  final VoidCallback onInfo;

  /// Non-null in the Story tab: render the same numbered, colour-neutral
  /// header every other narrative section uses there (Your Story
  /// deliberately doesn't badge visibility inline — see the file docstring).
  /// Null in Ayma's Notes: render the title + visibility-tag header every
  /// other note card uses there instead.
  final int? number;

  @override
  State<_AppearanceCard> createState() => _AppearanceCardState();
}

class _AppearanceCardState extends State<_AppearanceCard> {
  bool _running = false;

  Future<void> _runNow() async {
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
    final merge = widget.merge;
    final isAi = merge.visibility == 'ai';
    final bodyColor = isAi ? ac.fgDim : ac.fg;
    final reportId = merge.reportId;
    final hasReport = merge.hasReport;

    final reportBox = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_skillCardEyebrow('face-analysis'),
              style: AymaType.mono(size: 10, color: ac.fgMute).copyWith(letterSpacing: 1.4)),
          for (final part in merge.parts) ...[
            const SizedBox(height: 12),
            Text(part.label,
                style: AymaType.mono(size: 9, color: ac.fgMute).copyWith(letterSpacing: 1.2)),
            Builder(builder: (context) {
              if (part.section.userEdited) {
                return Text(part.section.body,
                    style: AymaType.sans(size: 14.5, color: bodyColor).copyWith(height: 1.6));
              }
              final teaser = _extractSkillTeaser(part.section.pageId, part.section.body);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (teaser.headline.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(teaser.headline,
                        style: AymaType.serif(size: 15, color: bodyColor).copyWith(height: 1.4)),
                  ],
                  if (teaser.detail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(teaser.detail, style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
                  ],
                ],
              );
            }),
          ],
          const SizedBox(height: 12),
          if (widget.publicView)
            const SizedBox.shrink()
          else if (hasReport)
            InkWell(
              // Any of the three page ids resolves to the same `/appearance/{id}`
              // path — `_skillReportPath` only special-cases `web-findings`.
              onTap: () => context.push(_skillReportPath('face-analysis', reportId!)),
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
                child: Text("Ayma hasn't finished a full report yet.",
                    style: AymaType.sans(size: 12, color: ac.fgMute)),
              ),
              if (_running)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: AymaOrb(size: 16, state: AymaOrbState.thinking),
                )
              else
                TextButton(onPressed: _runNow, child: const Text('Run it')),
            ]),
        ],
      ),
    );

    final footnote = InkWell(
      onTap: widget.onInfo,
      child: Text('Why Ayma believes this',
          style: AymaType.mono(size: 9.5, color: ac.fgMute).copyWith(letterSpacing: 0.8)),
    );

    if (widget.number != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.number!.toString().padLeft(2, '0')}  APPEARANCE ANALYSIS',
              style: AymaType.mono(size: 11, color: ac.accent).copyWith(letterSpacing: 2)),
          const SizedBox(height: 14),
          reportBox,
          const SizedBox(height: 10),
          if (!widget.publicView) footnote,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
              child: Text('Appearance analysis', style: AymaType.serif(size: 19, color: ac.fg))),
          Text(
            merge.visibility == 'public' ? 'PUBLIC' : (isAi ? 'AI ONLY' : 'PRIVATE'),
            style: AymaType.mono(size: 9, color: ac.fgMute).copyWith(letterSpacing: 1.2),
          ),
        ]),
        const SizedBox(height: 10),
        reportBox,
        const SizedBox(height: 10),
        footnote,
      ],
    );
  }
}
