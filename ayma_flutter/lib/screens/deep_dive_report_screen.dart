import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/deep_dive_activity.dart';
import '../theme.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../models/story_node.dart';
import '../widgets/graph_tree_view.dart';
import '../widgets/out_of_credits.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/report_progress.dart';
import '../widgets/share_report_sheet.dart';
import '../widgets/ayma_back_button.dart';

/// A stored web deep dive on one person, re-opened from a `[deep_dive:<id>]`
/// chat marker or the "View research" button on a profile — works
/// identically whether it's your own dive or someone else's (a non-owner
/// gets a read-only render; correction quick-actions are owner-only, per
/// `meta.viewer_can_edit`).
///
/// Body is the shared [GraphTreeView] Node-Visualiser (2o P2) via
/// `GET /report/deep_dive/{id}/tree` — summary sentences, facts, social links,
/// photos found online, and (for the owner) pending reverse-image-search
/// candidates ("Photos to confirm" — this screen is their ONLY home) all render
/// as nodes. A candidate's "This is me" / "Not me" routes through
/// `onCandidateVerdict` → the report's own confirm/reject quick action, then
/// reloads the body.
///
/// The AppBar actions are the only bespoke chrome this screen keeps. "Search
/// again" needs a couple of fields the tree doesn't carry (who the dive is
/// about, for `targetUid`) — those still come from the dedicated
/// `deepDiveReport` read, fetched alongside purely for that metadata.
class DeepDiveReportScreen extends StatefulWidget {
  const DeepDiveReportScreen({super.key, required this.reportId, this.apiClient});

  static const path = '/deep-dive/:id';

  final String reportId;
  final ApiClient? apiClient;

  @override
  State<DeepDiveReportScreen> createState() => _DeepDiveReportScreenState();
}

class _DeepDiveReportScreenState extends State<DeepDiveReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();

  /// AppBar-action metadata only — the render comes entirely from the body's
  /// own `GET /report/deep_dive/{id}/tree` fetch.
  DeepDiveReport? _meta;
  bool _reRunning = false;

  /// Lets a re-run reload the Node-Visualiser body in place.
  final _reportKey = GlobalKey<GraphTreeViewState>();

  bool _wasSearching = false;

  /// "Searching the web again…" (banner + AppBar spinner) shows only while a
  /// run is genuinely in flight: the POST is out, or [DeepDiveActivity] is
  /// polling a run the server still reports `running`.
  bool get _searching =>
      _reRunning || DeepDiveActivity.instance.isSearching(widget.reportId);

  /// The last run didn't finish (failed, or the server timed it out).
  bool get _failed =>
      !_searching &&
      (DeepDiveActivity.instance.hasFailed(widget.reportId) ||
          _meta?.runStatus == 'failed');

  @override
  void initState() {
    super.initState();
    _wasSearching = DeepDiveActivity.instance.isSearching(widget.reportId);
    DeepDiveActivity.instance.searching.addListener(_onActivityChanged);
    DeepDiveActivity.instance.failed.addListener(_onActivityChanged);
    _loadMeta();
  }

  @override
  void dispose() {
    DeepDiveActivity.instance.searching.removeListener(_onActivityChanged);
    DeepDiveActivity.instance.failed.removeListener(_onActivityChanged);
    super.dispose();
  }

  /// Reads the AppBar metadata and the server's run status; a run the server
  /// still reports `running` (started before this screen opened, e.g. before
  /// an app restart) gets its poll resumed so the banner tracks it.
  void _loadMeta() {
    _api.deepDiveReport(widget.reportId).then((r) {
      if (!mounted) return;
      setState(() => _meta = r);
      if (r.runStatus == 'running') {
        _wasSearching = true;
        unawaited(DeepDiveActivity.instance.start(widget.reportId, api: _api));
      }
    }).catchError((_) {});
  }

  /// When our re-search just finished, pull the fresh report in.
  void _onActivityChanged() {
    if (!mounted) return;
    final now = DeepDiveActivity.instance.isSearching(widget.reportId);
    final justFinished = _wasSearching && !now;
    _wasSearching = now;
    setState(() {});
    if (justFinished) {
      _reportKey.currentState?.reload();
      _loadMeta();
    }
  }

  /// Re-run this search from scratch — works the same whether the report is
  /// about you or someone else; a forced dive always skips the reuse cache.
  /// The fresh result lands in chat when it's ready (same as any other
  /// dive), and reopening this report afterwards picks up the update.
  Future<void> _reRun(DeepDiveReport r) => _startRun(
        targetUid: r.isSelf ? '' : r.otherUid,
        name: r.name,
        firstRun: false,
      );

  /// The run target implied by [widget.reportId] when NO report exists yet, so
  /// the empty state's "Run web search" can kick off the dive this screen is
  /// about without any report metadata (which also 404s when never run). A
  /// `uid_<subject>` id names an app user — the common never-run surface
  /// (a public profile / match / app-user chat marker); the server infers
  /// `is_self` when that subject is the caller. A `name_<slug>` id (a
  /// free-text lookup) runs by that name.
  ({String targetUid, String name}) _runTarget() {
    final id = widget.reportId;
    if (id.startsWith('uid_') && id.length > 'uid_'.length) {
      return (targetUid: id.substring('uid_'.length), name: '');
    }
    if (id.startsWith('name_') && id.length > 'name_'.length) {
      return (targetUid: '', name: id.substring('name_'.length).replaceAll('-', ' '));
    }
    return (targetUid: '', name: '');
  }

  /// Kicks off a web-research run (a first run from the empty state, or a
  /// forced re-run) and tracks its progress via [DeepDiveActivity] so the
  /// banner + spinner show and the report swaps in when it lands.
  Future<void> _startRun({
    required String targetUid,
    required String name,
    required bool firstRun,
  }) async {
    if (_reRunning) return;
    setState(() => _reRunning = true);
    try {
      final res = await _api.deepDive(
        targetUid: targetUid,
        name: name,
        force: true,
      );
      if (!mounted) return;
      if (res.usageCapped) {
        showOutOfCreditsSheet(context);
        return;
      }
      if (res.queued) {
        _wasSearching = true;
        unawaited(DeepDiveActivity.instance.start(widget.reportId, api: _api));
      }
      final again = firstRun ? '' : ' again';
      AymaToast.show(
          context,
          res.isSelf
              ? "Searching$again — I'll message you in chat when it's ready."
              : "Searching$again for ${name.isEmpty ? 'them' : name} — "
                  "I'll message you in chat when it's ready.");
    } catch (_) {
      if (!mounted) return;
      AymaToast.show(context, "Couldn't start a new search.",
          kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _reRunning = false);
    }
  }

  /// "This is me" / "Not me" on a pending reverse-image-search candidate —
  /// routed to the report's own confirm/reject quick action, then the body is
  /// reloaded so the resolved candidate drops out.
  Future<void> _onCandidateVerdict(StoryNode node, bool isMe) async {
    try {
      await _api.correctReport(
        'deep_dive',
        widget.reportId,
        blockIds: [node.id],
        scope: 'block',
        message: isMe ? 'this is me' : 'not me',
      );
      _reportKey.currentState?.reload();
    } catch (_) {
      if (mounted) {
        AymaToast.show(context, "Couldn't update that — try again.",
            kind: AymaToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        
        title: const Text('Web research'),
        actions: [
          ShareReportButton(
            reportType: 'deep_dive',
            reportId: widget.reportId,
            subjectUid: meta?.otherUid ?? '',
            subjectName: meta?.name ?? '',
            subjectPhoto: meta?.subjectImage ?? '',
            apiClient: _api,
          ),
          // Just the re-run action — the header "Ask Ayma" button was
          // removed as redundant with the nav-bar orb's page-context popup
          // (founder, 2026-09-26, same call as the public-profile header).
          if (meta != null)
            ReportRefreshButton(
              tooltip: 'Re-run',
              busyTooltip: 'Searching…',
              busy: _searching,
              onPressed: () => _reRun(meta),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_searching)
            ReportProgressBanner(
              message: meta == null
                  ? 'Searching the web…'
                  : 'Searching the web again…',
            )
          else if (_failed && meta != null)
            ReportFailedBanner(
              message: "Search didn't finish.",
              onRetry: () => _reRun(meta),
            ),
          Expanded(
            child: _searching && meta == null
                // First web search still running, nothing to show yet.
                ? const Center(
                    child: AymaWingLoader(lines: AymaLoaderLines.deepDive),
                  )
                // The body renders through the shared Node-Visualiser (2o P2).
                : GraphTreeView(
                    key: _reportKey,
                    surface: NodeVisualiserSurface.report,
                    reportType: 'deep_dive',
                    reportId: widget.reportId,
                    api: _api,
                    // "This is me" / "Not me" on a pending web-image candidate
                    // routes to the report's own confirm/reject, then reloads.
                    onCandidateVerdict: _onCandidateVerdict,
                    // A clean 404 means no dive has ever been run for this
                    // subject — an empty state with a "Run web search" action, not
                    // the "Couldn't load" error a real fetch failure gets.
                    emptyBuilder: (context) => _NoResearchYet(
                      busy: _reRunning,
                      onRun: () {
                        final t = _runTarget();
                        _startRun(
                          targetUid: t.targetUid,
                          name: t.name,
                          firstRun: true,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the web-research report has never been run for this subject
/// (a clean 404, not a load failure): an empty state inviting the owner to
/// start the first run, rather than an error that implies something broke.
class _NoResearchYet extends StatelessWidget {
  const _NoResearchYet({required this.onRun, required this.busy});

  final VoidCallback onRun;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return CenteredScroll(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.travel_explore, size: 40, color: ac.fgMute),
          const SizedBox(height: 16),
          Text(
            'No web research yet',
            textAlign: TextAlign.center,
            style: AymaType.serif(size: 20, color: ac.fg),
          ),
          const SizedBox(height: 8),
          Text(
            "Nothing has been searched on the open web for this person yet. "
            "Run a web search and I'll message you in chat when it's ready.",
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 14, color: ac.fgMute),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: busy ? null : onRun,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Run web search'),
            ),
          ),
        ],
      ),
    );
  }
}
