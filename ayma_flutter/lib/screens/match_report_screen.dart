import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/match_activity.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/living_report_view.dart';
import '../widgets/out_of_credits.dart';
import '../theme.dart';
import 'main_shell_screen.dart';

/// The shareable match report for one pair (§5.3). Opened from the "N% match"
/// chip on a public profile, or straight after "Run match". Shows both photos,
/// the score, what lines up / what doesn't, and the note Ayma wrote to you.
///
/// The score breakdown, narrative, dealbreakers and per-dimension rationale
/// now all come from the ONE shared [LivingReportView] renderer (§ generic
/// reports, `report_type: "match"` — see `report_adapters.match_blocks` /
/// `report_hub.py`). Only the two-person photo/score header and the
/// Confidence badge stay bespoke screen chrome around it — neither maps onto
/// any of the eight block types, the same reasoning `deep_dive_report_screen
/// .dart` uses to keep its own AppBar actions outside the generic body.
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
      if (justFinished) _future = _api.matchReport(widget.matchId);
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

  /// Hand this match report to the Ayma chat as a card + context.
  void _askAyma(MatchReport r) {
    ChatInbox.instance.push(ChatKickoff.talkAbout(
      targetUid: r.otherUid,
      label: r.otherName.isEmpty ? 'them' : r.otherName,
      shareKind: 'match',
      photoUrl: r.otherPhoto,
      refId: widget.matchId,
    ));
    context.go(MainShellScreen.path);
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
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _recalculating ? 'Recalculating…' : 'Recalculate',
                    onPressed:
                        _recalculating ? null : () => _recalculate(r.otherUid),
                    icon: _recalculating
                        ? const AymaOrb(size: 18, state: AymaOrbState.thinking)
                        : const Icon(Icons.refresh),
                  ),
                  TextButton(
                    onPressed: () => _askAyma(r),
                    child: const Text('Ask Ayma'),
                  ),
                ],
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
          return _Report(r: r, apiClient: _api);
        },
      ),
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({required this.r, required this.apiClient});

  final MatchReport r;
  final ApiClient apiClient;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final pct = r.score == null ? null : (r.score! * 100).round();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          // A soft accent-tinted card behind the score cluster — the one
          // piece of bespoke screen chrome (§ class doc) that isn't a block,
          // so it's the natural place to give the match's headline number
          // more presence ("eye candy instead of fully text" — the founder's
          // report) without inventing any new colors outside the app's
          // existing warm/minimal palette.
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            decoration: BoxDecoration(
              color: ac.accentFaint,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: ac.lineSoft),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Avatar(url: r.myPhoto, label: 'You'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Column(
                        children: [
                          Text(
                            pct == null ? '—' : '$pct%',
                            style: AymaType.serif(size: 40, color: ac.accent),
                          ),
                          Text('match',
                              style: AymaType.mono(size: 10, color: ac.fgMute)
                                  .copyWith(letterSpacing: 2)),
                        ],
                      ),
                    ),
                    _Avatar(
                        url: r.otherPhoto,
                        label: r.otherName.isEmpty
                            ? 'Them'
                            : r.otherName.split(' ').first),
                  ],
                ),
                if (r.confidenceBand.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _ConfidenceChip(
                      band: r.confidenceBand, note: r.confidenceNote),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: LivingReportView(
            reportType: 'match',
            reportId: r.matchId,
            apiClient: apiClient,
            emptyMessage: "Nothing to show for this match yet.",
          ),
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

/// "Confidence: High / Medium / Low" pill + the one-line note, shown just
/// under the score. Kept as bespoke screen chrome rather than folded into
/// the generic renderer's content — no block type maps onto a colored
/// confidence pill, and the report body's own top stat already carries a
/// compact confidence-band note on its `basis` without restating this full
/// sentence a second time (see `report_adapters.match_blocks`'s docstring).
class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.band, required this.note});
  final String band; // high | medium | low
  final String note;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = band == 'high'
        ? ac.success
        : band == 'medium'
            ? ac.warning
            : ac.error;
    final label = '${band[0].toUpperCase()}${band.substring(1)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_outlined, size: 13, color: color),
              const SizedBox(width: 6),
              Text('Confidence: $label',
                  style: AymaType.mono(size: 10, color: color)
                      .copyWith(letterSpacing: 0.5)),
            ],
          ),
        ),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(note,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)
                  .copyWith(height: 1.4)),
        ],
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
