import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/living_report.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/auto_retry.dart';
import '../services/report_cache.dart';
import '../services/report_events.dart';
import '../theme.dart';
import 'ask_ayma_overlay.dart';
import 'app_loading_indicator.dart';
import 'ayma_photo.dart';
import 'overflow_guards.dart';
import 'score_bar.dart';

/// The ONE shared, block-based renderer for every "Living Report" —
/// Appearance, deep-dive/web-search, and Story in each of its three view
/// modes (`story_private` / `story_public` / `story_ai_notes`). Fetches
/// `GET /report/{reportType}/{reportId}` and renders its `{title, sections}`
/// with three tap tiers plus ad-hoc multi-select, all routed through the
/// SAME mechanism: opening the shared Ask-Ayma chat modal
/// ([showAskAymaOverlay]) scoped via [AskAymaContext.reportType]/
/// [AskAymaContext.blockIds]/[AskAymaContext.scope], which
/// [AskAymaOrigin.report] turns into `POST
/// /report/{reportType}/{reportId}/correct` instead of a normal `/chat` turn
/// (see `ChatScreen._send`).
///
/// =============================================================================
/// GUARDRAIL — READ BEFORE ADDING ANY NEW REPORT-LIKE SCREEN OR FEATURE
/// =============================================================================
/// There is exactly ONE rendering pipeline for "report" content in this app:
///
///   producer's own data  --(adapter)-->  block model  --(routing)-->  THIS
///   (appearance.py,           report_          report_hub.py           widget
///    deep_dive.py,            adapters.py                            (below)
///    matching_skill.py,
///    story.py, ...)
///
/// Every current report type — Appearance, deep-dive, Story in all three
/// view modes (`story_private`/`story_public`/`story_ai_notes`), Match,
/// My-public-profile, and another member's public profile
/// (`public_profile`, the Explore tap-through — read-only for everyone) —
/// goes through that SAME pipeline and renders through this SAME widget,
/// full-screen or embedded (see [shrinkWrap] below).
///
/// A new report-like feature — a new report type, or a new kind of score /
/// stat / fact / finding an existing screen wants to show — MUST extend this
/// pipeline:
///   * a new block type or field in `report_blocks.py`, and/or
///   * a new (or extended) adapter function in `report_adapters.py` that
///     reshapes an existing producer's real data into blocks, and/or
///   * new routing for a new `report_type` in `report_hub.py`,
/// then rendered here, through [LivingReportView] — NOT through a new,
/// separate, bespoke widget tree that re-implements section headings, stat
/// bars, fact rows, tap-to-correct, etc. from scratch.
///
/// **Do not build a parallel, bespoke rendering system that quietly
/// re-displays content this widget already renders.** That is exactly how
/// the Match report shipped showing the SAME score and confidence band
/// TWICE — once in `match_report_screen.dart`'s bespoke header chrome, once
/// as this widget's own `stat` block — before that duplication was found
/// (the founder's own screenshot: "31% match" / "Confidence: Low" appearing
/// once as chrome, then again moments later as a block) and removed. A host
/// screen may keep a SMALL amount of bespoke chrome around this widget only
/// for things that genuinely cannot be a block — a photo carousel or avatar
/// header, AppBar actions like "Recalculate"/"Search again" — never for a
/// value a block already carries, and never pinned above/beside this
/// widget's own scroll in a way that stops the screen scrolling as one
/// region (see [shrinkWrap]).
///
/// Every screen that embeds this widget carries its own short pointer
/// comment back to this paragraph, right next to whatever bespoke chrome it
/// keeps, so the constraint is visible at both ends:
/// `match_report_screen.dart`, `deep_dive_report_screen.dart`,
/// `appearance_report_screen.dart`, `my_public_profile_screen.dart`,
/// `public_profile_screen.dart`, `story_editor_screen.dart`.
/// =============================================================================
///
/// [reportId] means something different per [reportType] — mirrors
/// `report_hub.resolve_owner`: the caller's own uid for every type except
/// `"deep_dive"` (a real, previously-run deep-dive report id),
/// `"match"` (a sorted-pair key), and `"public_profile"` (the OTHER
/// person's uid — the profile being viewed); the rest have exactly one
/// report per user, so their "id" IS the caller's uid.
///
/// --- Typography contract (§ founder: one hierarchy, not one per screen) ---
/// Exactly three roles, applied nowhere else in this file:
///  * [_titleStyle]   — the report's own title. Serif display, size 24.
///  * [_headingStyle] — a section heading. Mono, all-caps letter-spaced
///    eyebrow, size 11 — matches Story's existing numbered-section
///    convention, now the ONE section-heading style everywhere.
///  * [_bodyStyle]    — flowing sentence/prose text (`text` blocks). The
///    app's standard sans (Geist) body style, size 14, line-height 1.5 —
///    the exact same `AymaType.sans` treatment the public-profile view's
///    old bespoke renderer used for its narrative (§ founder 2026-09-26:
///    "change the font of the text to be the same as the text in the
///    public view right now. Keep the title and everything else the same
///    font."), shared by every report type's narrative text instead of
///    each screen picking its own. (Replaces the earlier serif-17
///    treatment inherited from Story's pre-Living-Report prose.)
/// Structured line-item blocks (fact/attribute/photo/link/stat) are UI
/// chrome around that prose, not prose themselves — they use the app's
/// ordinary sans body/label styles, same as Appearance/deep-dive already did,
/// not [_bodyStyle].
class LivingReportView extends StatefulWidget {
  const LivingReportView({
    super.key,
    required this.reportType,
    required this.reportId,
    this.apiClient,
    this.emptyMessage = 'Nothing here yet.',
    this.onLoaded,
    this.shrinkWrap = false,
    this.showTitle = true,
    this.loader,
    this.hideBlock,
    this.myUid,
    this.emptyBuilder,
  });

  final String reportType;
  final String reportId;
  final ApiClient? apiClient;

  /// The signed-in uid the stale-while-revalidate cache is scoped to.
  /// Injectable for tests; production reads the live Firebase uid. Empty /
  /// null disables caching (nothing is read or written).
  final String? myUid;

  /// Shown in place of the section list when the report has no sections at
  /// all.
  final String emptyMessage;

  /// When true, the internal section list sizes to its content and never
  /// scrolls on its own (`shrinkWrap: true` + `NeverScrollableScrollPhysics`)
  /// — for a caller (Story's editor screen — § generic reports) that embeds
  /// this widget as one item inside ITS OWN outer scrollable alongside other,
  /// not-yet-block-modeled content (cover stats, the photo gallery, the
  /// career timeline, the merged Appearance card) rather than giving this
  /// report the whole screen the way deep-dive/My-public-profile do.
  /// Default `false` (an independently scrolling full-screen list) is
  /// unchanged for every other caller.
  final bool shrinkWrap;

  /// When false, the report's own title (report-tier tap target) is
  /// omitted — for the same Story embedding [shrinkWrap] serves: Story's own
  /// screen already shows a large title of its own ("Your Story" / "Public
  /// view" / "Ayma's Notes") in its cover, so this report's title would
  /// otherwise repeat it immediately above the very same narrative content.
  /// The report-tier tap itself is still reachable there — a whole-report
  /// correction just isn't a headline UI affordance in that context.
  final bool showTitle;

  /// Fires every time the report (re)loads successfully — lets a host
  /// screen react to fresh data (e.g. an AppBar action that needs the
  /// report's own name) without this widget knowing about that screen's
  /// concerns.
  final void Function(LivingReport report)? onLoaded;

  /// Replaces the default `GET /report/{reportType}/{reportId}` fetch — the
  /// read-only shared-report view loads a public snapshot instead.
  final Future<LivingReport> Function()? loader;

  /// Blocks this returns true for are not drawn (a section left with none of
  /// its blocks is dropped) — for a host screen that shows them elsewhere.
  final bool Function(ReportBlock block)? hideBlock;

  /// Rendered in place of the retry error ONLY when the fetch came back a
  /// clean 404 — the server's unambiguous "this report has never been run"
  /// signal (`report_hub.get_report` -> `KeyError` -> 404), as opposed to a
  /// 5xx / transport failure of an existing report (which still shows the
  /// "Couldn't load that report." retry). Lets a host screen (web research)
  /// offer a "Run web search" call-to-action instead of an error. When null,
  /// a never-run 404 falls back to the same retry message as any other load
  /// failure — unchanged behaviour for every report type that doesn't supply
  /// one.
  final WidgetBuilder? emptyBuilder;

  @override
  State<LivingReportView> createState() => LivingReportViewState();
}

class LivingReportViewState extends State<LivingReportView>
    with ScreenContextReasserter<LivingReportView> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();

  /// The last successfully loaded report, kept mounted across a reload
  /// (§ `reload` doc: stale-while-revalidate, not swap-for-a-spinner) —
  /// `null` only before the very first load resolves AND no cached copy was
  /// restored.
  LivingReport? _report;
  bool _loadFailed = false;

  /// The fetch came back a clean 404 — the server's "nothing has ever been
  /// run for this subject" signal, distinct from [_loadFailed] (a 5xx /
  /// transport error on a report that may well exist). Drives [emptyBuilder]
  /// instead of the retry error.
  bool _neverRun = false;

  /// Silent auto-retry before ever surfacing the manual "Retry" affordance
  /// (founder 2026-11-01: a transient backend cold-start blip should
  /// self-heal, not dump the user on an error screen). A load that fails with
  /// anything OTHER than a definitive 404 is retried up to [kAutoRetryMax]
  /// times with the [kAutoRetryBackoff] delays (the ONE shared load-retry
  /// policy — see `auto_retry.dart`), staying on the loading/spinner (or
  /// stale) state the whole time; only once those are exhausted does
  /// [_loadFailed] flip and the manual Retry show. This sits ABOVE the HTTP
  /// layer's own per-request handling — it covers the case where the whole
  /// load still failed (e.g. a cold-start timeout) — and is bounded (at most
  /// [kAutoRetryMax] extra attempts + the summed backoff) so it can never
  /// retry forever.
  ///
  /// Bumped on every fresh [_load] invocation so an in-flight auto-retry loop
  /// from a superseded call (a background [ReportEvents] reload, a manual
  /// Retry, a post-exchange reload) abandons itself mid-backoff instead of
  /// racing the newer one.
  int _loadGeneration = 0;

  /// The signed-in uid the report cache is scoped to (own-data only). Empty
  /// in tests / signed out, which disables caching gracefully.
  String get _uid {
    final injected = widget.myUid;
    if (injected != null) return injected;
    try {
      return FirebaseAuth.instance.currentUser?.uid ?? '';
    } catch (_) {
      // No Firebase app configured (unit tests): no caching, just fetch.
      return '';
    }
  }

  /// Only the user's OWN report (the default network fetch) is cached — the
  /// read-only public-snapshot path ([LivingReportView.loader]) is someone
  /// else's data keyed differently, so it's never cached here.
  bool get _cacheable => widget.loader == null;

  /// The last [ReportEvents] revision for this report type we've already
  /// reacted to, so a background completion triggers exactly one reload.
  int _handledRevision = 0;

  /// Ad-hoc multi-select (§ founder point 4): every block id the user has
  /// checked, across any section, any combination. Non-empty <=> selection
  /// mode is active.
  final Set<String> _selected = {};

  /// [reportType] -> the [AppContext] screen slug it should track as, for
  /// the (only) caller that gives this widget the whole screen with no
  /// bespoke chrome of its own ([LivingReportView.shrinkWrap] false —
  /// `deep_dive_report_screen.dart`).
  /// Every other current [reportType] embeds with `shrinkWrap: true`
  /// (`match_report_screen.dart` and `appearance_report_screen.dart` keep
  /// their own richer tracking; `my_public_profile_screen.dart`/
  /// `story_editor_screen.dart` track their own screen once for the whole
  /// page instead) — see
  /// [reassertScreenContext]'s early return.
  static const _screenSlugs = {
    'deep_dive': 'deep_dive_report',
  };

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    _handledRevision = ReportEvents.instance.revisionFor(widget.reportType);
    ReportEvents.instance.addListener(_onReportEvent);
    // Stale-while-revalidate (founder: the heavy report pages "take time to
    // load, should we cache them? — yes"): paint the last cached copy
    // instantly if there is one, then always fetch fresh in the background.
    _restoreFromCache();
    _load();
  }

  @override
  void dispose() {
    ReportEvents.instance.removeListener(_onReportEvent);
    super.dispose();
  }

  /// A background run of this report type finished elsewhere in the app
  /// (§ `report_events.dart`) — re-fetch so the open report shows the fresh
  /// result without the user reloading by hand (founder 2026-10-28 bug).
  /// Fires at most once per completion by tracking the handled revision.
  void _onReportEvent() {
    final rev = ReportEvents.instance.revisionFor(widget.reportType);
    if (rev == _handledRevision) return;
    _handledRevision = rev;
    _load();
  }

  /// Best-effort synchronous-feeling restore of the last cached payload. Only
  /// fills `_report` when nothing has loaded yet, so a fresh fetch that has
  /// already landed (or a reload's in-place content) is never clobbered by
  /// stale cache.
  Future<void> _restoreFromCache() async {
    if (!_cacheable) return;
    try {
      final raw = await ReportCache.instance
          .readReport(_uid, widget.reportType, widget.reportId);
      if (raw == null || !mounted || _report != null) return;
      final report =
          LivingReport.fromMap(jsonDecode(raw) as Map<String, dynamic>);
      if (!mounted || _report != null) return;
      setState(() => _report = report);
      widget.onLoaded?.call(report);
    } catch (_) {
      // A corrupt / unreadable cache entry just means we wait for the network
      // fetch — never surface it.
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    // Re-running after a prior failure (a manual Retry, or a re-trigger):
    // drop the error state up front so the loading indicator — not the stale
    // error screen — is what shows during the fresh auto-retry sequence.
    if ((_loadFailed || _neverRun) && mounted) {
      setState(() {
        _loadFailed = false;
        _neverRun = false;
      });
    }
    for (var attempt = 0;; attempt++) {
      try {
        final r = await (widget.loader?.call() ??
            _api.getReport(widget.reportType, widget.reportId));
        // A newer _load superseded this one while the fetch was in flight —
        // let the newer one win rather than clobbering its result.
        if (generation != _loadGeneration || !mounted) return;
        if (_cacheable && r.source.isNotEmpty) {
          // Refresh the cache so the next open paints this instantly, and so
          // the background auto-refresh keeps the cache current too. `source`
          // is the exact server JSON this report was parsed from.
          unawaited(ReportCache.instance.writeReport(
              _uid, widget.reportType, widget.reportId, jsonEncode(r.source)));
        }
        setState(() {
          _report = r;
          _loadFailed = false;
          _neverRun = false;
        });
        widget.onLoaded?.call(r);
        return;
      } catch (e) {
        if (generation != _loadGeneration || !mounted) return;
        // A clean 404 is the server's definitive "never run" signal — route
        // it to [emptyBuilder], NOT the error retry, and never auto-retry it
        // (it isn't transient). Anything else (5xx, a connection-class
        // `ApiException` with no statusCode, a timeout) is a genuine —
        // typically transient — load failure, so silently retry it a few
        // times before surfacing the manual Retry.
        final neverRun = e is ApiException && e.statusCode == 404;
        if (!neverRun && attempt < kAutoRetryMax) {
          await Future<void>.delayed(kAutoRetryBackoff[attempt]);
          if (generation != _loadGeneration || !mounted) return;
          continue; // stay on the loading/stale state; try again
        }
        // Exhausted (or a never-run 404): surface the terminal state. A
        // background reload that fails here still leaves the already-good
        // `_report` on screen rather than blanking it out — the retry / empty
        // screen only shows when `_report` is still null (§ build).
        setState(() {
          if (neverRun) {
            _neverRun = true;
            _loadFailed = false;
          } else {
            _loadFailed = true;
          }
        });
        return;
      }
    }
  }

  /// Re-fetches the whole report — called once the Ask Ayma overlay closes
  /// on a turn that actually changed something, and when a background run of
  /// this report type completes ([_onReportEvent]). Deliberately does NOT tear
  /// down and rebuild the section list while the fetch is in flight (no
  /// `FutureBuilder`-style loading state once there's already a `_report` on
  /// screen — § bug: that swap used to unmount the `ListView` and reset its
  /// scroll offset to the top on every single dismiss, even a plain no-op
  /// one). The old content stays exactly where the user left it, in place,
  /// until the fresh data lands and swaps in.
  void reload() => _load();

  /// No-op for an embedded (`shrinkWrap: true`) instance — see
  /// [_screenSlugs]'s doc for why only the two whole-screen callers track
  /// anything here.
  @override
  void reassertScreenContext() {
    if (widget.shrinkWrap) return;
    AppContext.instance.set(
      screen: _screenSlugs[widget.reportType] ?? widget.reportType,
    );
  }

  bool get _selecting => _selected.isNotEmpty;

  void _enterSelection(String blockId) =>
      setState(() => _selected..clear()..add(blockId));

  void _toggle(String blockId) => setState(() {
        if (!_selected.remove(blockId)) _selected.add(blockId);
      });

  void _cancelSelection() => setState(_selected.clear);

  /// Whether [blockIds] should be treated as currently PRIVATE — decides
  /// whether the quick-action chip offers "Make public" (true) or "Make
  /// private" (false); see `AskAymaContext.isPrivate`'s own doc.
  ///
  /// For every report type except `story_public`, this is still the old
  /// report-type-level guess (the generic block model otherwise carries no
  /// visibility field at all): `story_public` shows only already-public
  /// content there -> `false`; everything else -> `true`.
  ///
  /// `story_public` itself is mixed (§ founder: physical-attribute fields
  /// are now private by default there, unlike Story's narrative passages):
  /// a narrative page/sentence block is always already-public (only
  /// `visibility == "public"` sections are ever included in that report at
  /// all), but an attribute block now carries its OWN real `public` flag —
  /// present only on the owner's own read, since that's the only read where
  /// a private field is shown at all (see `ReportBlock.public`'s doc). When
  /// every targeted block is one of those (the only way a tap can reach a
  /// private attribute in the first place), this reads their real state
  /// instead of the report-wide guess.
  bool _isPrivateFor(LivingReport report, List<String> blockIds) {
    if (widget.reportType != 'story_public') return true;
    final blocks = [
      for (final id in blockIds) report.blockById(id),
    ].whereType<ReportBlock>().toList();
    if (blocks.isEmpty) return false;
    final withKnownVisibility = blocks
        .where((b) => b.type == kBlockAttribute && b.public != null)
        .toList();
    if (withKnownVisibility.length == blocks.length) {
      return withKnownVisibility.any((b) => b.public != true);
    }
    return false;
  }

  /// Opens the shared chat modal scoped to [blockIds]/[scope]. When the
  /// current viewer can't edit this report, the correction fields are left
  /// unset (§ founder point 9: never wire a mutation attempt for a
  /// non-owner) — the modal still opens for genuine read-only Q&A, using
  /// [quoteTitle]/[quoteText] for context, via the normal `/chat` path.
  Future<void> _open({
    required LivingReport report,
    required List<String> blockIds,
    required String scope,
    required String quoteTitle,
    required String quoteText,
  }) async {
    final canEdit = report.meta.viewerCanEdit;
    final candidate = canEdit &&
        blockIds.isNotEmpty &&
        blockIds.every((id) => id.startsWith('candidate:'));
    setState(_selected.clear);
    // `onExchange` already re-fetches after every reply Ayma gives while the
    // modal is open (see `showAskAymaOverlay`'s doc) — that's the ONLY
    // reload this method triggers. A plain dismiss with no message sent (tap
    // outside, drag down, the X) fires no exchange, so nothing re-fetches
    // (§ bug: this used to unconditionally reload once more right here,
    // after every dismiss whether or not anything changed, which reset the
    // report's scroll position back to the top even on a genuine no-op).
    await showAskAymaOverlay(
      context,
      api: _api,
      ctx: AskAymaContext(
        origin: canEdit ? AskAymaOrigin.report : AskAymaOrigin.reportView,
        reportType: canEdit ? widget.reportType : '',
        reportId: canEdit ? widget.reportId : '',
        blockIds: canEdit ? blockIds : const [],
        scope: scope,
        isCandidate: candidate,
        isPrivate: _isPrivateFor(report, blockIds),
        quoteTitle: quoteTitle,
        quoteText: quoteText,
        // Match reports are always read-only (`canEdit` is never true for
        // this type — see the class doc), but Ayma should still be briefed
        // she's in a match-report conversation so a disputed underlying fact
        // routes to a profile fix + Recalculate rather than going unnoticed.
        matchReportId: widget.reportType == 'match' ? widget.reportId : '',
      ),
      onExchange: reload,
    );
  }

  /// Opens the shared Ask-Ayma chat modal scoped to the WHOLE report — the
  /// exact same mechanism the report's own title opens on tap (§ [_open]'s
  /// doc), exposed so a host screen's own "Ask Ayma" AppBar action can reuse
  /// it via a `GlobalKey<LivingReportViewState>` instead of rolling a second
  /// mechanism (§ founder: Match/deep-dive/etc.'s AppBar button used to push
  /// a pre-composed message into the main chat tab and navigate away from
  /// this screen — now it opens this same dockable, in-place modal with an
  /// empty composer, whether or not [showTitle] is true or the title is
  /// currently on screen). A no-op before the first load resolves.
  Future<void> askAymaAboutReport() async {
    final report = _report;
    if (report == null) return;
    await _open(
      report: report,
      blockIds: report.allBlockIds,
      scope: 'report',
      quoteTitle: report.title,
      quoteText: _reportSummary(report),
    );
  }


  void _openSection(LivingReport report, ReportSection section) => _open(
        report: report,
        blockIds: section.blockIds,
        scope: 'section',
        quoteTitle: section.heading,
        quoteText: _sectionSummary(section),
      );

  /// A short "what am I about to edit" summary for a whole-section tap — the
  /// quoted-context card (`_AskAymaHeader` in `chat_screen.dart`) only shows
  /// when `quoteText` is non-empty, and a single block already gets a real
  /// quote via [_quoteTextFor]. Section/report scope has no one block's text
  /// to quote, so this stands in: how many items are in scope, plus a short
  /// preview of their content when any block actually has quotable text
  /// (§ bug: this used to always pass `''`, so the card silently never
  /// appeared for a section/report tap — not "no context", just never wired).
  String _sectionSummary(ReportSection section) =>
      _scopeSummary(section.blockIds.length, section.blocks);

  /// Same idea as [_sectionSummary], for a whole-report tap.
  String _reportSummary(LivingReport report) {
    final n = report.sections.length;
    final sectionLabel = n == 1 ? '1 section' : '$n sections';
    final blocks = [for (final s in report.sections) ...s.blocks];
    return '$sectionLabel · ${_scopeSummary(report.allBlockIds.length, blocks)}';
  }

  String _scopeSummary(int itemCount, List<ReportBlock> blocks) {
    final itemLabel = itemCount == 1 ? '1 item' : '$itemCount items';
    final preview = blocks
        .map(_quoteTextFor)
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .take(3)
        .join(' · ');
    return preview.isEmpty ? itemLabel : '$itemLabel — $preview';
  }

  void _openBlock(LivingReport report, ReportBlock block) => _open(
        report: report,
        blockIds: [block.blockId],
        scope: 'block',
        quoteTitle: _quoteTitleFor(block),
        quoteText: _quoteTextFor(block),
      );

  void _openSelection(LivingReport report) => _open(
        report: report,
        blockIds: _selected.toList(),
        scope: 'block',
        quoteTitle: '${_selected.length} selected',
        quoteText: '',
      );

  String _quoteTitleFor(ReportBlock b) => switch (b.type) {
        kBlockAttribute => b.label,
        kBlockFact => b.tag.isNotEmpty ? b.tag : 'Claim',
        kBlockStat => b.label,
        kBlockLink => b.linkLabel.isNotEmpty ? b.linkLabel : 'Link',
        kBlockPhoto => b.isCandidate ? 'Photo to confirm' : 'Photo',
        _ => 'This',
      };

  String _quoteTextFor(ReportBlock b) => switch (b.type) {
        kBlockText || kBlockFact || kBlockSectionHead => b.text,
        kBlockAttribute => '${b.value}',
        kBlockStat => '${b.value}${b.basis.isEmpty ? '' : ' · ${b.basis}'}',
        kBlockPhoto => b.caption.isNotEmpty ? b.caption : b.url,
        kBlockLink => b.url,
        _ => '',
      };

  /// Whether [block] can be tapped/long-pressed at all: an `editable: false`
  /// block (§ `report_blocks.py`: "a client-side hint so a non-correctable
  /// block ... doesn't invite a tap that can only ever fail") is inert for
  /// an editing owner; a non-owner may still tap it for read-only Q&A.
  bool _tappable(ReportBlock b, bool canEdit) => !canEdit || b.editable;

  @override
  Widget build(BuildContext context) {
    final report = _report;
    if (report == null) {
      // A never-run 404 with a host-supplied empty state (web research's
      // "Run web search" call-to-action) shows that instead of the error.
      if (_neverRun && widget.emptyBuilder != null) {
        return widget.emptyBuilder!(context);
      }
      if (_loadFailed || _neverRun) return _ErrorMessage(onRetry: reload);
      // No cached copy to show yet: the standard page/report loader (shown
      // only when there's NO cache — a cached report paints instantly above
      // via `_restoreFromCache`, with the fresh fetch swapping in silently).
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: AppLoadingIndicator(),
        ),
      );
    }
    return _buildReport(context, report);
  }

  List<ReportSection> _visibleSections(LivingReport report) {
    final hide = widget.hideBlock;
    if (hide == null) return report.sections;
    return [
      for (final s in report.sections)
        if (s.blocks.isEmpty || s.blocks.any((b) => !hide(b)))
          ReportSection(
            heading: s.heading,
            blocks: [
              for (final b in s.blocks)
                if (!hide(b)) b,
            ],
          ),
    ];
  }

  /// A subtle `Updated <relative time>` line from the report's own generation
  /// timestamp (`meta.updated_at`, falling back to `created_at`). Returns a
  /// zero-size box when the report carries no parseable timestamp, so it never
  /// adds empty chrome. Uses `ValueKey('reportFreshness')` so a widget test can
  /// find it.
  Widget _buildFreshnessStamp(AymaTokens ac, LivingReport report) {
    final raw = (report.meta.updatedAt?.isNotEmpty ?? false)
        ? report.meta.updatedAt
        : report.meta.createdAt;
    final when = raw == null ? null : DateTime.tryParse(raw);
    if (when == null) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('reportFreshness'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        'Updated ${_relativeTime(when)}',
        style: AymaType.mono(size: 11, color: ac.fgMute)
            .copyWith(letterSpacing: 0.5),
      ),
    );
  }

  /// Short relative age for the freshness stamp — "just now", "5m ago",
  /// "3h ago", "2d ago" (same scale as the Messages list's "Last activity").
  static String _relativeTime(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.isNegative || d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _buildReport(BuildContext context, LivingReport report) {
    final ac = context.ac;
    final canEdit = report.meta.viewerCanEdit;
    final list = ListView(
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
        20, 16, 20, (_selecting && !widget.shrinkWrap) ? 96 : 40,
      ),
      children: [
            if (widget.showTitle) ...[
              GestureDetector(
                key: const ValueKey('livingReportTitle'),
                onTap: _selecting || report.allBlockIds.isEmpty
                    ? null
                    : () => askAymaAboutReport(),
                child: Text(report.title, style: _titleStyle(ac.fg)),
              ),
              const SizedBox(height: 24),
            ],
            // Freshness stamp (founder 2026-10-28: a background rerun gave no
            // signal it finished). Shows when the Appearance report was last
            // generated so the user can SEE it ran/refreshed even when the
            // content looks similar. Only on the Appearance report — the one
            // report that reruns in the background from elsewhere.
            if (widget.reportType == 'appearance') ...[
              _buildFreshnessStamp(ac, report),
            ],
            if (report.sections.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  widget.emptyMessage,
                  style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
                ),
              ),
            for (final section in _visibleSections(report)) ...[
              _SectionView(
                section: section,
                report: report,
                canEdit: canEdit,
                // Dev-facing per-fact annotations (tag/confidence) render only
                // inside the password-gated Ayma's-notes screen
                // (`story_ai_notes`), never in the normal UI any viewer sees.
                showDevAnnotations: widget.reportType == 'story_ai_notes',
                selected: _selected,
                selecting: _selecting,
                onHeadingTap: _selecting || section.blockIds.isEmpty
                    ? null
                    : () => _openSection(report, section),
                onBlockTap: (b) {
                  if (!_tappable(b, canEdit)) return;
                  if (_selecting) {
                    _toggle(b.blockId);
                  } else {
                    _openBlock(report, b);
                  }
                },
                onBlockLongPress: (b) {
                  if (!canEdit || !_tappable(b, canEdit)) return;
                  _enterSelection(b.blockId);
                },
              ),
              const SizedBox(height: 28),
            ],
      ],
    );

    final selectionBar = _SelectionBar(
      count: _selected.length,
      onCancel: _cancelSelection,
      onChat: () => _openSelection(report),
    );

    // Embedded (shrinkWrap) mode has no bounded viewport of its own to pin a
    // floating bar to (it sizes to its content, inside a HOST screen's own
    // outer scrollable) — the selection bar renders as a normal trailing
    // item instead of a `Positioned` overlay there; everywhere else
    // (deep-dive/My-public-profile/Story's own full-bleed use)
    // it's still the floating bottom bar.
    if (widget.shrinkWrap) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          list,
          if (_selecting) selectionBar,
        ],
      );
    }
    return Stack(
      children: [
        list,
        if (_selecting)
          Positioned(left: 0, right: 0, bottom: 0, child: selectionBar),
      ],
    );
  }
}

// --- typography (§ contract — see class doc) --------------------------------

TextStyle _titleStyle(Color color) => AymaType.serif(size: 24, color: color);

TextStyle _headingStyle(Color color) =>
    AymaType.mono(size: 15, color: color).copyWith(letterSpacing: 1.8);

// The one body/prose role (§ typography contract in the class doc): the
// exact sans body style the public-profile view's old bespoke `_Section`
// renderer used (`AymaType.sans(size: 14, height: 1.5)`) — reused, not a
// new literal of this file's own.
TextStyle _bodyStyle(Color color) =>
    AymaType.sans(size: 14, color: color, height: 1.5);

// --- section / block rendering ----------------------------------------------

class _SectionView extends StatelessWidget {
  const _SectionView({
    required this.section,
    required this.report,
    required this.canEdit,
    required this.showDevAnnotations,
    required this.selected,
    required this.selecting,
    required this.onHeadingTap,
    required this.onBlockTap,
    required this.onBlockLongPress,
  });

  final ReportSection section;
  final LivingReport report;
  final bool canEdit;

  /// Whether a fact's raw tag/confidence annotation is shown — true only for
  /// the dev-only Ayma's-notes report (`story_ai_notes`).
  final bool showDevAnnotations;
  final Set<String> selected;
  final bool selecting;
  final VoidCallback? onHeadingTap;
  final void Function(ReportBlock) onBlockTap;
  final void Function(ReportBlock) onBlockLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // Consecutive `text` blocks render as one continuous flowing paragraph
    // (§ founder point 2) rather than one row per sentence; every other
    // block type gets its own row widget, in original order.
    final rows = <Widget>[];
    var run = <ReportBlock>[];
    void flush() {
      if (run.isEmpty) return;
      rows.add(_ProseFlow(
        blocks: run,
        selected: selected,
        onTap: onBlockTap,
        onLongPress: onBlockLongPress,
      ));
      run = [];
    }

    for (final b in section.blocks) {
      if (b.type == kBlockText) {
        run.add(b);
        continue;
      }
      flush();
      rows.add(_BlockRow(
        block: b,
        showDevAnnotations: showDevAnnotations,
        selected: selected.contains(b.blockId),
        selecting: selecting,
        onTap: () => onBlockTap(b),
        onLongPress: () => onBlockLongPress(b),
      ));
    }
    flush();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          key: ValueKey('livingReportSection:${section.heading}'),
          onTap: onHeadingTap,
          child: Text(section.heading.toUpperCase(), style: _headingStyle(ac.accent)),
        ),
        const SizedBox(height: 12),
        for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 10), child: r),
      ],
    );
  }
}

/// One or more consecutive `text` blocks flowed as continuous prose. Each
/// sentence is its own tap target via [WidgetSpan] (not a bare
/// [TextSpan.recognizer]) so it can show a real highlight background and a
/// real hit-test rect — a small inline [TextSpan] tap is exactly the
/// "fragile bare inline tap" § founder point 2 calls out. A short tap opens
/// the block-scoped Edit-with-Ayma flow for just that one sentence, exactly
/// like a short tap on any other block type (§ bug fix: this used to be
/// long-press-only — the sentence's [GestureDetector.onTap] was wired to
/// `null` outside selection mode, and the parent's `onBlockTap` additionally
/// skipped every `text` block on a plain tap — so a normal single tap on
/// narrative prose silently did nothing at all, while every other block
/// type (fact/attribute/stat/...) opened immediately. That's the exact
/// regression the founder's screenshot reported: "anything written in this
/// font is not clickable to edit," reproducing on every report type because
/// this widget is the one shared renderer for all of them). Long-press still
/// enters ad-hoc multi-select, same as everywhere else; once already
/// selecting, a short tap toggles the sentence into/out of the selection.
class _ProseFlow extends StatelessWidget {
  const _ProseFlow({
    required this.blocks,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final List<ReportBlock> blocks;
  final Set<String> selected;
  final void Function(ReportBlock) onTap;
  final void Function(ReportBlock) onLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final style = _bodyStyle(ac.fg);
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Sentence(
                block: blocks[i],
                style: style,
                isSelected: selected.contains(blocks[i].blockId),
                onTap: () => onTap(blocks[i]),
                onLongPress: () => onLongPress(blocks[i]),
              ),
            ),
            if (i != blocks.length - 1) TextSpan(text: ' ', style: style),
          ],
        ],
      ),
    );
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence({
    required this.block,
    required this.style,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  final ReportBlock block;
  final TextStyle style;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // `tone` recolours this ONE sentence — never a new typography role (see
    // the "Typography contract" note atop this file): same [_bodyStyle]
    // font/size/weight, just a different [color]. `private` -> the app's existing muted
    // "dimmed" tone; `ai_only` -> the app's existing red "removed" tone (see
    // `story.py`'s own docstring) — never the raw `{{private}}`/`{{ai_only}}`
    // delimiters themselves, which `story.sentence_spans` already stripped
    // server-side before this text ever reached the client.
    final toned = switch (block.tone) {
      'private' => style.copyWith(color: ac.fgMute),
      'ai_only' => style.copyWith(color: ac.error),
      _ => style,
    };
    return GestureDetector(
      key: ValueKey('livingReportBlock:${block.blockId}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? ac.accent.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: _LinkifiedText(block.text, style: toned),
      ),
    );
  }
}

/// A structured, single-line-item block (fact/attribute/photo/photo_grid/
/// link/stat/section_head) — a row, not prose. Short tap opens chat for just
/// this block outside selection mode; long-press enters selection mode.
class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.block,
    required this.showDevAnnotations,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final ReportBlock block;
  final bool showDevAnnotations;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final child = switch (block.type) {
      kBlockSectionHead => Text(block.text,
          style: AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
      kBlockFact =>
        _FactRow(block: block, showDevAnnotations: showDevAnnotations),
      kBlockAttribute => _AttributeRow(block: block),
      kBlockStat => _StatRow(block: block),
      kBlockLink => _LinkRow(block: block),
      kBlockPhoto => _PhotoRow(block: block),
      kBlockPhotoGrid => _PhotoGridRow(block: block),
      _ => _LinkifiedText(block.text,
          style: AymaType.sans(size: 14, color: ac.fg)),
    };
    return GestureDetector(
      key: ValueKey('livingReportBlock:${block.blockId}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? ac.accent.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selecting) ...[
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: selected ? ac.accent : ac.fgMute,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.block, required this.showDevAnnotations});
  final ReportBlock block;

  /// Whether the model's raw tag/confidence annotation is shown — true only in
  /// the dev-only, password-gated Ayma's-notes screen (`story_ai_notes`), never
  /// in the normal UI any viewer sees.
  final bool showDevAnnotations;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final conf = block.confidence.isEmpty ? '' : ' · ${block.confidence}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LinkifiedText('• ${block.text}',
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
        if (showDevAnnotations && (block.tag.isNotEmpty || conf.isNotEmpty))
          Padding(
            key: const ValueKey('fact-dev-annotation'),
            padding: const EdgeInsets.only(left: 14, top: 2),
            child: Text('${block.tag}$conf',
                style: AymaType.mono(size: 9, color: ac.fgMute)),
          ),
      ],
    );
  }
}

class _AttributeRow extends StatelessWidget {
  const _AttributeRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 128,
          child: Text(block.label, style: AymaType.sans(size: 13, color: ac.fgMute)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${block.value}',
              style: AymaType.sans(size: 14, color: ac.fg, height: 1.35)),
        ),
        // Owner-only (`block.public` is only ever non-null on the owner's
        // own story_public read — see `ReportBlock.public`'s doc): a plain
        // "PRIVATE" tag so they can tell, at a glance, which attributes a
        // stranger visiting their public Story does NOT see.
        if (block.public == false)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text('PRIVATE',
                style: AymaType.mono(size: 9, color: ac.fgMute)),
          ),
      ],
    );
  }
}

/// A `stat` block (§ `report_blocks.STAT`) — the ONE generic score/number
/// renderer shared by every report type that has one: Match's overall score
/// and per-dimension compatibility scores, Face/Body's `overall_score`
/// (surfaced through Appearance's own Living Report — `_axis_blocks` ->
/// `report_blocks.scored_result_blocks`), deep-dive's word-valued
/// "Confidence" stat. Previously this rendered as plain digits next to a
/// label — the founder's report: Match "lost all its graphics" once it
/// converged onto this shared renderer, where Face/Body had a real
/// [ScoreBar] via their own bespoke screens. This draws a real bar for any
/// numeric stat instead, generically — nothing here is Match-specific.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.block});
  final ReportBlock block;

  /// Parses [value] into a plain numeric score. Handles both a raw number
  /// (Face/Body's `overall_score`, Match's per-dimension `score` —
  /// `report_adapters.match_blocks`) and a pre-formatted "NN%" string
  /// (Match's top-line `score` stat, formatted server-side as a percentage
  /// string rather than a raw float). Returns null for a non-numeric value
  /// (e.g. deep-dive's "Confidence": "High"/"Medium"/"Low"), which falls
  /// back to [_NonNumericStat] below rather than a bar.
  static double? _numericValue(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final s = value.trim();
      final unsigned = s.endsWith('%') ? s.substring(0, s.length - 1) : s;
      return double.tryParse(unsigned.trim());
    }
    return null;
  }

  /// The scale [value] is measured against. The block model carries no
  /// explicit `max` field, so this infers 0-100 vs 0-10 from the same
  /// signals every current producer's data already carries: a literal "%"
  /// suffix on the value, or a "NN% weight" fragment in [basis] (both mean
  /// Match's dimension-score scale, 0-100 — `matching_skill._merge_dimensions`
  /// clamps every dimension score to `[0, 100]`); anything else numeric is
  /// assumed 0-10 (Face/Body's `overall_score`, always 0-10 per
  /// `face_report.run`/`body_report.run`'s own schema) unless the value
  /// itself is already above 10, which can only mean the 0-100 scale.
  static double _impliedMax(Object? value, String basis) {
    if (value is String && value.trim().endsWith('%')) return 100;
    if (RegExp(r'\d+%\s*weight').hasMatch(basis)) return 100;
    final n = _numericValue(value);
    return (n != null && n > 10) ? 100 : 10;
  }

  /// [basis] (e.g. "22% weight · measured") with any trailing "measured"/
  /// "estimated" source word pulled out into its own field so it can be
  /// styled as a small colored tag instead of buried in plain gray prose —
  /// `(rest-of-basis, sourceWord-or-null)`.
  static (String, String?) _splitBasis(String basis) {
    if (basis.isEmpty) return ('', null);
    final parts = basis
        .split('·')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    String? source;
    final rest = <String>[];
    for (final p in parts) {
      final lower = p.toLowerCase();
      if (source == null && (lower == 'measured' || lower == 'estimated')) {
        source = lower;
      } else {
        rest.add(p);
      }
    }
    return (rest.join(' · '), source);
  }

  /// Banded green/amber/red by fraction-of-max — the same "gauge quality at
  /// a glance" judgment Match's dimensions are meant to read as (§
  /// `ScoreBar`'s own doc). Used whenever [max] is the 0-100 "compatibility
  /// percentage" scale; a 0-10 rating (Face/Body) stays flat/accent, same
  /// as those screens' own bespoke bar today.
  static Color _bandColor(BuildContext context, double value, double max) {
    final ac = context.ac;
    final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    if (frac >= 0.7) return ac.success;
    if (frac >= 0.4) return ac.warning;
    return ac.error;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final value = block.value;
    final n = _numericValue(value);
    if (n == null) return _NonNumericStat(block: block);

    final max = _impliedMax(value, block.basis);
    final banded = max >= 100;
    final display = banded ? '${n.round()}%' : '${n.toStringAsFixed(1)}/10';
    final (basisRest, source) = _splitBasis(block.basis);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              flex: 2,
              child: Text(block.label,
                  style: AymaType.sans(
                      size: 13.5, weight: FontWeight.w600, color: ac.fg)),
            ),
            const SizedBox(width: 8),
            // At most a third of the row, so a long value at large text
            // wraps instead of pushing the row off screen.
            Flexible(
              child: Text(display,
                  textAlign: TextAlign.end,
                  style: AymaType.serif(
                      size: 18,
                      color:
                          banded ? _bandColor(context, n, max) : ac.accent)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ScoreBar(
          value: n,
          max: max,
          height: 6,
          colorFor: banded ? _bandColor : null,
        ),
        if (basisRest.isNotEmpty || source != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (basisRest.isNotEmpty)
                Flexible(
                  child: Text(basisRest,
                      style: AymaType.sans(size: 12, color: ac.fgMute)),
                ),
              if (basisRest.isNotEmpty && source != null)
                const SizedBox(width: 6),
              if (source != null) _SourceTag(source: source),
            ],
          ),
        ],
      ],
    );
  }
}

/// A source-of-truth tag ("measured" vs "estimated" — see
/// `report_adapters.match_blocks`'s `measured`/`estimated` label) as a small
/// colored pill with an icon instead of plain gray text, so the two read as
/// distinct at a glance rather than blending into the rest of the caption.
class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.source});
  final String source; // 'measured' | 'estimated'

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final measured = source == 'measured';
    final color = measured ? ac.success : ac.fgMute;
    final icon = measured ? Icons.check_circle : Icons.auto_awesome;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(source.toUpperCase(),
              style: AymaType.mono(size: 8, color: color)
                  .copyWith(letterSpacing: 0.6)),
        ],
      ),
    );
  }
}

/// A `stat` block whose value isn't a number at all — deep-dive's
/// "Confidence" ("High"/"Medium"/"Low", no numeric scale to bar). A
/// recognized band word still gets a colored pill (same green/amber/red
/// vocabulary as the numeric banded bars, and as Match's own header
/// Confidence chip — `match_report_screen._ConfidenceChip`); anything else
/// falls back to the original plain label/value line.
class _NonNumericStat extends StatelessWidget {
  const _NonNumericStat({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final valueStr = '${block.value}';
    final band = valueStr.trim().toLowerCase();
    if (band == 'high' || band == 'medium' || band == 'low') {
      final color =
          band == 'high' ? ac.success : (band == 'medium' ? ac.warning : ac.error);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Text(valueStr,
                style: AymaType.mono(size: 10, color: color)
                    .copyWith(letterSpacing: 0.5)),
          ),
          if (block.label.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(block.label,
                  style: AymaType.sans(size: 12.5, color: ac.fgMute)),
            ),
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(valueStr, style: AymaType.serif(size: 22, color: ac.fg)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            [block.label, block.basis].where((s) => s.isNotEmpty).join(' · '),
            style: AymaType.sans(size: 12.5, color: ac.fgMute),
          ),
        ),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isSocial = block.blockId.startsWith('social:');
    final label = block.linkLabel.isNotEmpty ? block.linkLabel : block.url;
    return Row(
      children: [
        if (isSocial) ...[
          Icon(_socialIcon(block.tag), size: 16, color: ac.accent),
          const SizedBox(width: 8),
          if (block.tag.isNotEmpty)
            Text(
              _socialName(block.tag),
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: isSocial ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: AymaType.sans(size: 13, color: ac.accent, height: 1.35),
          ),
        ),
        // A link's own "visit it" affordance lives here, separate from the
        // row's general tap (which opens chat about this block) — a link is
        // the one block type whose primary use is leaving the app, not
        // talking about it.
        if (block.url.isNotEmpty)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openUrl(block.url),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.open_in_new, size: 14, color: ac.accent),
            ),
          ),
      ],
    );
  }
}

IconData _socialIcon(String platform) => switch (platform.toLowerCase()) {
      'github' => Icons.code,
      'youtube' => Icons.play_circle_outline,
      'instagram' => Icons.camera_alt_outlined,
      'linkedin' => Icons.work_outline,
      'x' => Icons.alternate_email,
      'facebook' => Icons.people_outline,
      'tiktok' => Icons.music_note,
      _ => Icons.public,
    };

String _socialName(String platform) => switch (platform.toLowerCase()) {
      'github' => 'GitHub',
      'youtube' => 'YouTube',
      'linkedin' => 'LinkedIn',
      'tiktok' => 'TikTok',
      'x' => 'X',
      final p => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1),
    };

/// Opens [url] in the external browser; ignores anything that isn't a
/// parseable http(s) URL.
Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No handler available — nothing more to do.
  }
}

final _urlPattern = RegExp(r'https?:\/\/[^\s<>"]+');

/// Plain text in which every bare http(s) URL is a tappable link.
class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText(this.text, {required this.style});
  final String text;
  final TextStyle style;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    _disposeRecognizers();
    if (!_urlPattern.hasMatch(text)) return Text(text, style: widget.style);
    final link = context.ac.accent;
    final spans = <InlineSpan>[];
    var idx = 0;
    for (final m in _urlPattern.allMatches(text)) {
      if (m.start > idx) spans.add(TextSpan(text: text.substring(idx, m.start)));
      var url = m.group(0)!;
      var tail = '';
      while (url.isNotEmpty && '.,!?:;)]}'.contains(url[url.length - 1])) {
        tail = url[url.length - 1] + tail;
        url = url.substring(0, url.length - 1);
      }
      final target = url;
      final rec = TapGestureRecognizer()..onTap = () => _openUrl(target);
      _recognizers.add(rec);
      spans.add(TextSpan(
        text: url,
        style: TextStyle(color: link, decoration: TextDecoration.underline),
        recognizer: rec,
      ));
      if (tail.isNotEmpty) spans.add(TextSpan(text: tail));
      idx = m.end;
    }
    if (idx < text.length) spans.add(TextSpan(text: text.substring(idx)));
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final hasUrl = block.url.trim().isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('photoRowThumb'),
          borderRadius: BorderRadius.circular(10),
          onTap: hasUrl ? () => _openUrl(block.url) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 72,
              height: 72,
              child: AymaPhoto(
                url: block.url,
                displayWidth: 72,
                // Hotlink-protected / expired signed CDN URLs (e.g. TikTok)
                // can't be loaded in-app — offer the link instead.
                error: Container(
                  color: ac.bgCard,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.open_in_new, color: ac.accent, size: 18),
                      const SizedBox(height: 2),
                      Text('Open photo link',
                          textAlign: TextAlign.center,
                          style: AymaType.sans(size: 9, color: ac.accent)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (block.isPending)
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ac.accentFaint,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('PENDING',
                      style: AymaType.mono(size: 8, color: ac.accent)
                          .copyWith(letterSpacing: 1)),
                ),
              if (block.caption.isNotEmpty)
                InkWell(
                  key: const ValueKey('photoRowCaption'),
                  onTap: hasUrl ? () => _openUrl(block.url) : null,
                  child: Text(
                    block.caption,
                    style: AymaType.sans(
                      size: 12.5,
                      soft: true,
                      color: hasUrl ? ac.accent : ac.fgMute,
                    ).copyWith(
                      decoration: hasUrl ? TextDecoration.underline : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoGridRow extends StatelessWidget {
  const _PhotoGridRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final photos = block.photos;
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 76,
            height: 76,
            child: AymaPhoto(
              url: photos[i]['url'] as String? ?? '',
              displayWidth: 76,
              error: Container(
                color: ac.bgCard,
                child: Icon(Icons.broken_image_outlined, color: ac.fgMute, size: 18),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "N selected · Chat about these / Cancel" (§ founder point 4).
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onCancel,
    required this.onChat,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: ac.bgElev,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text('$count selected',
                    style: AymaType.sans(size: 14, color: ac.fg)),
              ),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: count == 0 ? null : onChat,
                child: const Text('Chat about these'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return CenteredScroll(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't load that report.",
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, color: ac.fgMute)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
