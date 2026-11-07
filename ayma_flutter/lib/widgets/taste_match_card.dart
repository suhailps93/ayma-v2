import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'taste_models.dart';

const _unavailable = 'Taste match unavailable right now.';

/// Fetches the taste match for [otherUid]. Never throws: every failure
/// becomes a [TasteMatchLoad.note], so the date-sim screen can't break.
///
/// The wait is bounded (§ SIMTASTE): the sim-screen card shows "Comparing…"
/// until this resolves, while the match report renders resolved data with no
/// wait — a hung fetch left the sim card spinning forever. The HTTP layer
/// times out the POST itself, but the auth-token fetch ahead of it has no
/// deadline, so this timeout (past the HTTP budget, so a slow-but-working
/// taste resolve still renders) degrades only a true hang to the honest empty
/// below — absent, never an error card (§ BUG A).
Future<TasteMatchLoad> loadTasteMatch(ApiClient api, String otherUid) async {
  try {
    final match = await api
        .tastePair(otherUid)
        .timeout(api.longTimeout + const Duration(seconds: 5));
    return TasteMatchLoad.match(match);
  } on NoTasteException catch (e) {
    return TasteMatchLoad.note(e.message);
  } catch (_) {
    return const TasteMatchLoad.note(_unavailable);
  }
}

/// "Taste match" — the overlap score, summary, shared tastes
/// and date ideas. Shown under the date-sim compatibility read and as a section
/// in the match report. While [load] is pending it shows a muted "comparing"
/// line; when there's a match with real overlap substance it shows that. When
/// there's NO taste content to show — one side has no public Taste page, the
/// The taste lookup failed / degraded, OR the pair's graphs simply don't overlap
/// (a 200 with no per-domain bars / shared favourites / tags / date ideas, only
/// a bare score + "quite different taste graphs" line) — the card is simply
/// ABSENT (an empty [SizedBox]), never a bare/blank card: Taste is an optional
/// enrichment, not something whose absence the user needs told about (§ founder
/// BUG A — a 200 "no taste data" was being turned into a "Taste match
/// unavailable right now." error card; § founder: a 200 with no overlap was
/// painting a blank/near-empty card on the sim screen).
class TasteMatchCard extends StatelessWidget {
  const TasteMatchCard({super.key, required this.load});

  /// For data already resolved (e.g. embedded in the match report payload):
  /// renders immediately, no pending state.
  TasteMatchCard.resolved(TasteMatchLoad value, {super.key})
      : load = Future<TasteMatchLoad>.value(value);

  final Future<TasteMatchLoad> load;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return FutureBuilder<TasteMatchLoad>(
      future: load,
      builder: (context, snap) {
        final m = snap.data?.match;
        // Resolved with nothing substantive to show — no Taste page, a failure,
        // or a 200 whose graphs don't overlap (no bars/shared/tags/ideas, just a
        // bare score + summary) → the card is absent, not a blank/error card.
        // Only a still-pending load keeps the card up, for its "comparing" line.
        final show = m != null && m.hasOverlap;
        if (snap.connectionState == ConnectionState.done && !show) {
          return const SizedBox.shrink();
        }
        return Container(
          key: const Key('tasteMatchCard'),
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: ac.bgCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ac.lineSoft, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(ac, sample: m?.isSample == true),
              const SizedBox(height: 12),
              // Reached only when pending (m == null → the comparing line) or
              // with a substantive match (the `!show` guard above returned for
              // a resolved-but-empty one), so a non-null m here always renders.
              if (m != null)
                ..._body(ac, m)
              else
                Text(
                  'Comparing your tastes…',
                  key: const Key('tasteMatchLoading'),
                  style: AymaType.sans(size: 13.5, color: ac.fgMute),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(AymaTokens ac, {required bool sample}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.local_dining_outlined, size: 20, color: ac.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Taste match',
                style: AymaType.sans(
                    size: 15, weight: FontWeight.w700, color: ac.fg),
              ),
            ],
          ),
        ),
        if (sample)
          Flexible(
            child: Container(
              key: const Key('tasteMatchSampleChip'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: ac.line, width: 0.5),
              ),
              child: Text(
                'sample data',
                overflow: TextOverflow.ellipsis,
                style: AymaType.sans(size: 11, color: ac.fgDim),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _body(AymaTokens ac, TasteMatch m) {
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${m.score}',
            key: const Key('tasteMatchScore'),
            style: AymaType.sans(
                size: 28, weight: FontWeight.w800, color: ac.accent),
          ),
          Text('/100', style: AymaType.sans(size: 13, color: ac.fgDim)),
          const SizedBox(width: 10),
          if (m.scoreLabel.isNotEmpty)
            Expanded(
              child: Text(
                m.scoreLabel,
                style: AymaType.sans(
                    size: 14, weight: FontWeight.w600, color: ac.fg),
              ),
            ),
        ],
      ),
      if (m.domains.isNotEmpty) ...[
        const SizedBox(height: 12),
        Column(
          key: const Key('tasteMatchDomains'),
          children: [
            for (final d in _orderedDomains(m.domains))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _DomainBar(label: _title(d.domain), score: d.score),
              ),
          ],
        ),
      ],
      if (m.summary.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          m.summary,
          style: AymaType.sans(size: 14, color: ac.fg, height: 1.45),
        ),
      ],
      if (m.sharedTags.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          'Why you match',
          style: AymaType.sans(
              size: 11.5, weight: FontWeight.w600, color: ac.fgMute),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('tasteMatchSharedTags'),
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in m.sharedTags)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: ac.accent, width: 0.5),
                ),
                child: Text(
                  t,
                  style: AymaType.sans(size: 12.5, color: ac.fgDim),
                ),
              ),
          ],
        ),
      ],
      if (m.demographics != null) ...[
        const SizedBox(height: 10),
        Text(
          m.demographics!.note,
          key: const Key('tasteMatchDemographics'),
          style: AymaType.sans(size: 12, color: ac.fgMute, height: 1.4),
        ),
      ],
      if (m.shared.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          'You both listed',
          style: AymaType.sans(
              size: 11.5, weight: FontWeight.w600, color: ac.fgMute),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('tasteMatchShared'),
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final s in m.shared)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: ac.accentFaint,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  s,
                  style: AymaType.sans(size: 12.5, color: ac.fg),
                ),
              ),
          ],
        ),
      ],
      if (m.dateIdeas.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          "Date ideas you'd both enjoy",
          style: AymaType.sans(
              size: 13.5, weight: FontWeight.w600, color: ac.fgDim),
        ),
        for (final idea in m.dateIdeas) ...[
          const SizedBox(height: 10),
          _IdeaRow(idea: idea),
        ],
      ],
    ];
  }

  /// Maps a raw domain key to its display label, matching the public demo
  /// (`taste_demo.html`): `dining` reads as "Food & places"; anything else is
  /// title-cased.
  static String _title(String s) {
    switch (s) {
      case 'music':
        return 'Music';
      case 'film':
        return 'Film';
      case 'dining':
        return 'Food & places';
      default:
        return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
    }
  }

  /// The domains in the demo's fixed order — Music, Film, Food & places —
  /// with any further domains kept in their original order after those.
  static List<TasteDomain> _orderedDomains(List<TasteDomain> domains) {
    const order = ['music', 'film', 'dining'];
    final sorted = [...domains];
    sorted.sort((a, b) {
      final ia = order.indexOf(a.domain);
      final ib = order.indexOf(b.domain);
      if (ia == -1 && ib == -1) return 0;
      if (ia == -1) return 1;
      if (ib == -1) return -1;
      return ia.compareTo(ib);
    });
    return sorted;
  }
}

/// One per-domain overlap row: the domain label, a horizontal 0–100 progress
/// bar (accent fill on a faint track), and the numeric score at the right —
/// reproducing the `.dom` row of the public demo (`taste_demo.html`). Every
/// part is overflow-proof at textScale 2.0: the label wraps/ellipsizes inside
/// a fixed column, the bar flexes, and the value column scales with the text.
class _DomainBar extends StatelessWidget {
  const _DomainBar({required this.label, required this.score});

  final String label;
  final int score;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final clamped = score.clamp(0, 100);
    final scaler = MediaQuery.textScalerOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AymaType.sans(size: 12.5, color: ac.fgDim),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                Container(height: 8, color: ac.line),
                FractionallySizedBox(
                  widthFactor: clamped / 100,
                  child: Container(height: 8, color: ac.accent),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: scaler.scale(26),
          child: Text(
            '$clamped',
            textAlign: TextAlign.right,
            maxLines: 1,
            style: AymaType.sans(
              size: 12.5,
              weight: FontWeight.w600,
              color: ac.fg,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    );
  }
}

class _IdeaRow extends StatelessWidget {
  const _IdeaRow({required this.idea});

  final TasteDateIdea idea;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      key: const Key('tasteMatchIdea'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            text: idea.name,
            style: AymaType.sans(
                size: 14, weight: FontWeight.w600, color: ac.fg),
            children: [
              if (idea.kind.isNotEmpty)
                TextSpan(
                  text: '  ${idea.kind}',
                  style: AymaType.sans(size: 12, color: ac.fgMute),
                ),
            ],
          ),
        ),
        if (idea.why.isNotEmpty)
          Text(
            idea.why,
            style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.4),
          ),
        if (idea.address != null && idea.address!.isNotEmpty)
          Text(
            idea.address!,
            style: AymaType.sans(size: 12, color: ac.fgMute),
          ),
      ],
    );
  }
}
