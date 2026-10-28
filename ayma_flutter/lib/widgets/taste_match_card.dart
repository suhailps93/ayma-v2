import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'taste_models.dart';

const _unavailable = 'Taste match unavailable right now.';

/// Fetches the taste match for [otherUid]. Never throws: every failure
/// becomes a [TasteMatchLoad.note], so the date-sim screen can't break.
Future<TasteMatchLoad> loadTasteMatch(ApiClient api, String otherUid) async {
  try {
    return TasteMatchLoad.match(await api.tastePair(otherUid));
  } on NoTasteException catch (e) {
    return TasteMatchLoad.note(e.message);
  } catch (_) {
    return const TasteMatchLoad.note(_unavailable);
  }
}

/// "Taste match · powered by Qloo" — the overlap score, summary, shared tastes
/// and date ideas. Shown under the date-sim compatibility read and as a section
/// in the match report. While [load] is pending it shows a muted "comparing"
/// line; when it resolves to a note (no Taste page, or any failure) it shows
/// that note instead.
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
        final note = snap.data?.note ?? (snap.hasError ? _unavailable : null);
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
              if (m != null)
                ..._body(ac, m)
              else if (note != null)
                Text(
                  note,
                  key: const Key('tasteMatchNote'),
                  style:
                      AymaType.sans(size: 13.5, color: ac.fgDim, height: 1.4),
                )
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
              Text(
                'powered by Qloo',
                style: AymaType.sans(size: 11.5, color: ac.fgMute),
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
        const SizedBox(height: 4),
        Text(
          m.domains.map((d) => '${_title(d.domain)} ${d.score}').join(' · '),
          key: const Key('tasteMatchDomains'),
          style: AymaType.sans(size: 12.5, color: ac.fgDim),
        ),
      ],
      if (m.summary.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          m.summary,
          style: AymaType.sans(size: 14, color: ac.fg, height: 1.45),
        ),
      ],
      if (m.shared.isNotEmpty) ...[
        const SizedBox(height: 12),
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

  static String _title(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
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
