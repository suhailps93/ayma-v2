import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../widgets/ayma_photo.dart';
import '../theme.dart';

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

class _MatchReportScreenState extends State<MatchReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late Future<MatchReport?> _future = _api.matchReport(widget.matchId);
  bool _recalculating = false;

  @override
  void initState() {
    super.initState();
    _future.then((r) {
      if (mounted && r != null) {
        AppContext.instance.set(
          screen: 'match_report',
          subjectUid: r.otherUid,
          subjectName: r.otherName,
        );
      }
    }).catchError((_) {});
  }

  Future<void> _recalculate(String otherUid) async {
    if (_recalculating || otherUid.isEmpty) return;
    setState(() => _recalculating = true);
    try {
      // force: true — skip the cached score and re-run the rubric. The job runs
      // server-side, so poll the report until a fresh score lands.
      final before = await _future;
      final res = await _api.checkCompatibility(otherUid, force: true);
      if (!mounted) return;
      if (res.usageCapped) {
        _snack('Out of credits — reload on your profile.');
      } else if (res.queued) {
        final fresh = await _pollForNewScore(before?.score);
        if (!mounted) return;
        if (fresh) {
          _snack('Match updated.');
        } else {
          _snack('Still recalculating — check back in a moment.');
          setState(() => _future = _api.matchReport(widget.matchId));
        }
      } else {
        setState(() => _future = _api.matchReport(widget.matchId));
      }
    } catch (_) {
      _snack("Couldn't recalculate that match.");
    } finally {
      if (mounted) setState(() => _recalculating = false);
    }
  }

  /// Poll the report until its score differs from [previous] (or we give up).
  /// Returns true once a changed score is on screen.
  Future<bool> _pollForNewScore(double? previous) async {
    for (var i = 0; i < 20 && mounted; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return false;
      try {
        final r = await _api.matchReport(widget.matchId);
        if (r != null && r.score != null && r.score != previous) {
          setState(() => _future = Future.value(r));
          return true;
        }
      } catch (_) {
        // transient — keep polling
      }
    }
    return false;
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
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
  });

  final MatchReport r;
  final bool recalculating;
  final VoidCallback onRecalculate;
  final VoidCallback onCopy;

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
        const SizedBox(height: 24),
        if (r.explanation.isNotEmpty)
          Text(
            r.explanation,
            style: AymaType.serif(size: 16, color: ac.fg).copyWith(height: 1.5),
          ),
        if (r.dimensions.isNotEmpty) ...[
          const SizedBox(height: 26),
          Text('HOW THIS SCORE IS BUILT',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 4),
          Text(
            'Seven weighted dimensions from relationship research (Big Five, '
            'attachment, Gottman, dating-data dealbreakers). Overall = the '
            'weighted average.',
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
                label: const Text('Recalculate'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Share'),
              ),
            ),
          ],
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
