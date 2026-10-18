import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/match_activity.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/living_report_view.dart';
import '../widgets/out_of_credits.dart';
import '../theme.dart';

/// The shareable match report for one pair (§5.3). Opened from the "N% match"
/// chip on a public profile, or straight after "Run match". Shows both
/// photos, the score, what lines up / what doesn't, and the note Ayma wrote
/// to you.
///
/// --- Bespoke chrome vs. the Living Report — see the GUARDRAIL in
/// `living_report_view.dart`'s own file doc before adding anything here. ---
/// The score breakdown, confidence band, narrative, dealbreakers and
/// per-dimension rationale ALL come from the ONE shared [LivingReportView]
/// renderer (§ generic reports, `report_type: "match"` — see
/// `report_adapters.match_blocks` / `report_hub.py`); its own top-of-section
/// `stat` block ("Match score", e.g. "31%", basis "Low confidence") is the
/// ONLY place the score and confidence band are rendered. Only the
/// two-person avatar/photo row stays bespoke screen chrome — photos aren't a
/// block type at all, the same reasoning `deep_dive_report_screen.dart` uses
/// to keep its own AppBar actions outside the generic body. This screen used
/// to ALSO print a big score digit and a separate "Confidence: Low" chip
/// here in the header — a real duplication bug (the founder's screenshot:
/// "31% match" / "Confidence: Low" shown once as chrome and again, moments
/// later, as the block-rendered "Match score" stat) — removed; do not bring
/// either back without also removing the block that already shows it.
///
/// The avatar row and the [LivingReportView] body render inside ONE
/// scrolling list ([LivingReportView.shrinkWrap], the same
/// embedded-inline-in-an-outer-`ListView` pattern `my_public_profile_screen
/// .dart` and `story_editor_screen.dart` use) — nothing on this screen stays
/// pinned while the rest scrolls (§ founder: "Don't keep this part frozen,
/// let it also scroll").
///
/// Match reports are read + informational-chat-only: `report_hub` never sets
/// `meta.viewer_can_edit` for this report type, for either participant, so
/// [LivingReportView] never offers a quick-action/tap-to-correct affordance
/// here — every tap opens plain, read-only Ask-Ayma chat about the report. A
/// match score is algorithmically computed (`matching_skill.score_pair`),
/// not user-authored content the way a Story passage or an Appearance
/// finding is, so there's nothing to "correct" via a stated-value override;
/// a stray write attempt still gets a clear, deliberate reply server-side
/// (`report_hub.correct`'s explicit "nothing to correct" branch) rather than
/// silently no-op'ing.
class MatchReportScreen extends StatefulWidget {
  const MatchReportScreen({
    super.key,
    required this.matchId,
    this.apiClient,
  });

  static const path = '/match';

  final String matchId;
  final ApiClient? apiClient;

  @override
  State<MatchReportScreen> createState() => _MatchReportScreenState();
}

class _MatchReportScreenState extends State<MatchReportScreen>
    with ScreenContextReasserter<MatchReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late Future<MatchReport?> _future = _api.matchReport(widget.matchId);
  bool _sendingRecalc = false;
  bool _wasRecalculating = false;
  String _subjectUid = '';
  String _subjectName = '';

  /// Lets "Recalculate" reload [LivingReportView] too: the score/confidence/
  /// narrative shown to the user lives ENTIRELY in the embedded view, so a
  /// recalculation must explicitly reload it, not just the `_future` this
  /// AppBar's own action reads from — otherwise it would visibly do nothing.
  final _reportKey = GlobalKey<LivingReportViewState>();

  bool get _recalculating =>
      _sendingRecalc || MatchActivity.instance.isRecalculating(widget.matchId);

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    MatchActivity.instance.recalculating.addListener(_onActivityChanged);
    _future.then((r) {
      if (mounted && r != null) {
        _subjectUid = r.otherUid;
        _subjectName = r.otherName;
        reassertScreenContext();
      }
    }).catchError((_) {});
  }

  @override
  void reassertScreenContext() => AppContext.instance.set(
        screen: 'match_report',
        subjectUid: _subjectUid,
        subjectName: _subjectName,
      );

  @override
  void dispose() {
    MatchActivity.instance.recalculating.removeListener(_onActivityChanged);
    super.dispose();
  }

  /// The global recalc set changed. Rebuild for the spinner; when our job just
  /// finished, pull the fresh report in.
  void _onActivityChanged() {
    if (!mounted) return;
    final now = MatchActivity.instance.isRecalculating(widget.matchId);
    final justFinished = _wasRecalculating && !now;
    _wasRecalculating = now;
    setState(() {
      if (justFinished) {
        _future = _api.matchReport(widget.matchId);
        _reportKey.currentState?.reload();
      }
    });
  }

  Future<void> _recalculate(String otherUid) async {
    if (_recalculating || otherUid.isEmpty) return;
    setState(() => _sendingRecalc = true);
    try {
      // force: true — skip the cached score and re-run the rubric.
      final before = await _future;
      final res = await _api.checkCompatibility(otherUid, force: true);
      if (!mounted) return;
      if (res.usageCapped) {
        showOutOfCreditsSnack(context);
      } else if (res.queued) {
        // Hand the poll to MatchActivity so it keeps running (and the chip
        // keeps spinning) even if the user leaves this screen.
        _wasRecalculating = true;
        _snack("Recalculating — this keeps running if you leave.");
        unawaited(MatchActivity.instance
            .start(widget.matchId, previousScore: before?.score, api: _api));
      } else {
        setState(() => _future = _api.matchReport(widget.matchId));
        _reportKey.currentState?.reload();
      }
    } catch (_) {
      _snack("Couldn't recalculate that match.");
    } finally {
      if (mounted) setState(() => _sendingRecalc = false);
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Match'),
        actions: [
          FutureBuilder<MatchReport?>(
            future: _future,
            builder: (context, snap) {
              final r = snap.data;
              if (r == null) return const SizedBox.shrink();
              return IconButton(
                tooltip: _recalculating ? 'Recalculating…' : 'Recalculate',
                onPressed:
                    _recalculating ? null : () => _recalculate(r.otherUid),
                icon: const Icon(Icons.refresh),
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<MatchReport?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: AymaOrb(size: 64, state: AymaOrbState.thinking));
          }
          final r = snap.data;
          if (snap.hasError) {
            return _Message(
              text: "Couldn't load this match.",
              onRetry: () => setState(
                  () => _future = _api.matchReport(widget.matchId)),
            );
          }
          if (r == null) {
            return const _Message(
                text: 'This match hasn\'t been scored yet.');
          }
          return _Report(r: r, apiClient: _api, reportKey: _reportKey);
        },
      ),
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({required this.r, required this.apiClient, required this.reportKey});

  final MatchReport r;
  final ApiClient apiClient;
  final GlobalKey<LivingReportViewState> reportKey;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // ONE scrolling list for the whole screen (§ class doc: "don't keep this
    // part frozen") — the avatar-row chrome below is just its first item,
    // the same embedded-inline pattern `my_public_profile_screen.dart` /
    // `story_editor_screen.dart` use for their own bespoke chrome ahead of
    // [LivingReportView]. Nothing here is `Expanded`/pinned above a
    // separately-scrolling body any more.
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          // A soft accent-tinted card behind the two avatars — the ONLY
          // piece of bespoke screen chrome this screen keeps (§ class doc):
          // photos aren't a block type, so there's nothing to converge onto
          // in the Living Report. It deliberately shows NO score digit and
          // NO confidence text any more — both now come exactly once, from
          // the report body's own "Match score" stat block just below.
          child: Container(
            key: const ValueKey('matchHeaderCard'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            decoration: BoxDecoration(
              color: ac.accentFaint,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: ac.lineSoft),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Avatar(url: r.myPhoto, label: 'You'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Icon(Icons.favorite_rounded,
                      size: 20, color: ac.accent),
                ),
                _Avatar(
                    url: r.otherPhoto,
                    label: r.otherName.isEmpty
                        ? 'Them'
                        : r.otherName.split(' ').first),
              ],
            ),
          ),
        ),
        // `shrinkWrap: true` — embedded as one item of the outer `ListView`
        // above rather than given the whole screen (§ class doc; see
        // [LivingReportView.shrinkWrap]'s own doc for why). This is where
        // the score, confidence band, and narrative actually render — do
        // not re-add them to the header card above.
        LivingReportView(
          key: reportKey,
          reportType: 'match',
          reportId: r.matchId,
          apiClient: apiClient,
          emptyMessage: "Nothing to show for this match yet.",
          shrinkWrap: true,
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.label});
  final String url;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ac.bgCard,
            border: Border.all(color: ac.lineSoft),
          ),
          clipBehavior: Clip.antiAlias,
          child: url.isEmpty
              ? Icon(Icons.person, color: ac.fgMute, size: 32)
              : AymaPhoto(
                  url: url,
                  displayWidth: 72,
                  error: Icon(Icons.person, color: ac.fgMute, size: 32),
                ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 84,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AymaType.sans(size: 12, color: ac.fgMute),
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 14, color: context.ac.fgMute)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
