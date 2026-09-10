import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/match_activity.dart';
import '../widgets/ayma_photo.dart';
import '../theme.dart';
import 'main_shell_screen.dart';

/// The shareable match report for one pair (§5.3). Opened from the "N% match"
/// chip on a public profile, or straight after "Run match". Shows both photos,
/// the score, what lines up / what doesn't, and the note Ayma wrote to you.
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
        _snack('Out of credits — reload on your profile.');
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

  void _copy(MatchReport r) {
    final pct = r.score == null ? '—' : '${(r.score! * 100).round()}%';
    final b = StringBuffer()
      ..writeln('Match with ${r.otherName.isEmpty ? 'them' : r.otherName}: $pct')
      ..writeln();
    if (r.explanation.isNotEmpty) b..writeln(r.explanation)..writeln();
    if (r.dimensions.isNotEmpty) {
      b.writeln('Breakdown:');
      for (final d in r.dimensions) {
        b.writeln('• ${d.label}: ${d.score.round()}/100');
      }
      b.writeln();
    }
    if (r.shared.isNotEmpty) {
      b.writeln('In common:');
      for (final s in r.shared) {
        b.writeln('• $s');
      }
      b.writeln();
    }
    if (r.tensions.isNotEmpty) {
      b.writeln('Where you differ:');
      for (final s in r.tensions) {
        b.writeln('• $s');
      }
    }
    Clipboard.setData(ClipboardData(text: b.toString().trim()));
    _snack('Match summary copied');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Match')),
      body: FutureBuilder<MatchReport?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
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
          return _Report(
            r: r,
            recalculating: _recalculating,
            onRecalculate: () => _recalculate(r.otherUid),
            onCopy: () => _copy(r),
            onAskAyma: () => _askAyma(r),
          );
        },
      ),
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({
    required this.r,
    required this.recalculating,
    required this.onRecalculate,
    required this.onCopy,
    required this.onAskAyma,
  });

  final MatchReport r;
  final bool recalculating;
  final VoidCallback onRecalculate;
  final VoidCallback onCopy;
  final VoidCallback onAskAyma;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final pct = r.score == null ? null : (r.score! * 100).round();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
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
                    style: AymaType.serif(size: 34, color: ac.accent),
                  ),
                  Text('match',
                      style: AymaType.mono(size: 10, color: ac.fgMute)
                          .copyWith(letterSpacing: 2)),
                ],
              ),
            ),
            _Avatar(
                url: r.otherPhoto,
                label: r.otherName.isEmpty ? 'Them' : r.otherName.split(' ').first),
          ],
        ),
        if (r.confidenceBand.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ConfidenceChip(
              band: r.confidenceBand, note: r.confidenceNote),
        ],
        const SizedBox(height: 24),
        if (r.explanation.isNotEmpty)
          Text(
            r.explanation,
            style: AymaType.serif(size: 16, color: ac.fg).copyWith(height: 1.5),
          ),
        if (r.gateFailures.isNotEmpty) ...[
          const SizedBox(height: 22),
          _DealbreakersBlock(items: r.gateFailures),
        ],
        if (r.dimensions.isNotEmpty) ...[
          const SizedBox(height: 26),
          Text('HOW THIS SCORE IS BUILT',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 4),
          Text(
            r.method.isNotEmpty
                ? r.method
                : 'Seven weighted dimensions from relationship research (Big '
                    'Five, attachment, Gottman, dating-data dealbreakers). '
                    'Overall = the weighted average.',
            style: AymaType.sans(size: 11, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 12),
          for (final d in r.dimensions) _DimensionRow(d: d),
        ],
        if (r.shared.isNotEmpty) ...[
          const SizedBox(height: 24),
          _ListBlock(
            title: 'What lines up',
            items: r.shared,
            icon: Icons.check_circle_outline,
            color: ac.success,
          ),
        ],
        if (r.tensions.isNotEmpty) ...[
          const SizedBox(height: 20),
          _ListBlock(
            title: 'Where you differ',
            items: r.tensions,
            icon: Icons.remove_circle_outline,
            color: ac.warning,
          ),
        ],
        if (r.missing.isNotEmpty) ...[
          const SizedBox(height: 20),
          _ListBlock(
            title: "What'd sharpen this score",
            items: r.missing,
            icon: Icons.help_outline,
            color: ac.fgMute,
          ),
          const SizedBox(height: 6),
          Text(
            'These aren’t in either profile yet. Add them on your profile or '
            'tell Ayma, then recalculate.',
            style: AymaType.sans(size: 11, soft: true, color: ac.fgMute),
          ),
        ],
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: recalculating ? null : onRecalculate,
                icon: recalculating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 18),
                label: Text(recalculating ? 'Recalculating…' : 'Recalculate'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: onAskAyma,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Ask Ayma'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.content_copy, size: 15),
            label: const Text('Copy summary'),
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

/// One rubric dimension: label · weight, a 0–100 bar coloured by band, the
/// score, and (expandable) the rationale + evidence.
class _DimensionRow extends StatefulWidget {
  const _DimensionRow({required this.d});
  final MatchDimension d;

  @override
  State<_DimensionRow> createState() => _DimensionRowState();
}

class _DimensionRowState extends State<_DimensionRow> {
  bool _open = false;

  Color _band(AymaTokens ac, double s) => s >= 60
      ? ac.success
      : s >= 40
          ? ac.warning
          : ac.error;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final d = widget.d;
    final pct = d.score.round();
    final barColor = _band(ac, d.score);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: (d.rationale.isEmpty && d.evidence.isEmpty)
            ? null
            : () => setState(() => _open = !_open),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(d.label,
                      style: AymaType.sans(size: 13, color: ac.fg)),
                ),
                _SourceTag(measured: d.isMeasured),
                const SizedBox(width: 8),
                Text('${(d.weight * 100).round()}%',
                    style: AymaType.mono(size: 9, color: ac.fgMute)),
                const SizedBox(width: 10),
                Text('$pct',
                    style: AymaType.mono(size: 12, color: barColor)),
                if (d.rationale.isNotEmpty || d.evidence.isNotEmpty)
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: ac.fgMute),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                children: [
                  Container(height: 6, color: ac.bgCard),
                  FractionallySizedBox(
                    widthFactor: (d.score / 100).clamp(0.0, 1.0),
                    child: Container(height: 6, color: barColor),
                  ),
                ],
              ),
            ),
            if (_open) ...[
              const SizedBox(height: 8),
              if (d.rationale.isNotEmpty)
                Text(d.rationale,
                    style: AymaType.sans(size: 12, color: ac.fgMute)
                        .copyWith(height: 1.4)),
              for (final e in d.evidence)
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 2),
                  child: Text('· $e',
                      style: AymaType.sans(size: 11, color: ac.fgMute)),
                ),
              if (d.confidence != 'high')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${d.confidence} confidence — limited notes here',
                      style: AymaType.mono(size: 9, color: ac.fgMute)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Confidence: High / Medium / Low" pill + the one-line note, shown just
/// under the score.
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

/// Hard dealbreakers the deterministic pass found — a loud red block above
/// "what lines up".
class _DealbreakersBlock extends StatelessWidget {
  const _DealbreakersBlock({required this.items});
  final List<MatchGateFailure> items;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: ac.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ac.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.block, size: 16, color: ac.error),
              const SizedBox(width: 8),
              Text('DEALBREAKERS',
                  style: AymaType.mono(size: 10, color: ac.error)
                      .copyWith(letterSpacing: 1.4)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'These hard mismatches cap the score on their own.',
            style: AymaType.sans(size: 11, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 8),
          for (final g in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (g.label.isNotEmpty)
                    Text(g.label,
                        style: AymaType.sans(size: 13, color: ac.fg)),
                  Text(g.reason,
                      style: AymaType.sans(size: 12, color: ac.fgMute)
                          .copyWith(height: 1.4)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Small "measured" vs "estimated" pill on a dimension row.
class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.measured});
  final bool measured;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = measured ? ac.success : ac.fgMute;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(measured ? 'measured' : 'estimated',
          style: AymaType.mono(size: 8, color: color)),
    );
  }
}

class _ListBlock extends StatelessWidget {
  const _ListBlock({
    required this.title,
    required this.items,
    required this.icon,
    required this.color,
  });

  final String title;
  final List<String> items;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(),
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.4)),
        const SizedBox(height: 10),
        for (final s in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 10),
                  child: Icon(icon, size: 16, color: color),
                ),
                Expanded(
                  child: Text(s,
                      style: AymaType.sans(size: 14, color: ac.fg)
                          .copyWith(height: 1.4)),
                ),
              ],
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
