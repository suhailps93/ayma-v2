import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// The elegant structured career/education timeline (§ Your Story career
/// timeline) — rendered only when the section's `CareerTimeline.showTimeline`
/// gate is true; otherwise Career & Education stays flowing prose like any
/// other section. Tapping a row opens Ask Ayma scoped to that one entry (via
/// `AskAymaContext.timelineEntryId`) so a correction goes straight to
/// `edit_career_timeline_entry` / `delete_career_timeline_entry`, never the
/// passage-offset mechanism, which doesn't fit structured fields.
class CareerTimelineView extends StatelessWidget {
  const CareerTimelineView({
    super.key,
    required this.entries,
    required this.onTapEntry,
  });

  final List<TimelineEntry> entries;
  final ValueChanged<TimelineEntry> onTapEntry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < entries.length; i++)
          _TimelineRow(
            entry: entries[i],
            isLast: i == entries.length - 1,
            onTap: () => onTapEntry(entries[i]),
          ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.entry,
    required this.isLast,
    required this.onTap,
  });

  final TimelineEntry entry;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isWork = entry.kind == 'work';
    // Real confidence, restrained: only entries the client ever shows are
    // already high/medium (the confidence gate keeps low out entirely) — a
    // medium read gets a quiet dotted underline, never a percentage.
    final uncertain = entry.confidence == 'medium';

    return Semantics(
      button: true,
      label:
          '${entry.org}${entry.titleOrDegree.isNotEmpty ? ', ${entry.titleOrDegree}' : ''}'
          '${entry.dateRange.isNotEmpty ? ', ${entry.dateRange}' : ''}',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          // The connector line's `Expanded` needs a bounded height to fill —
          // `IntrinsicHeight` gives this Row (otherwise unbounded, sitting
          // inside a scrollable) a real height derived from its content, so
          // the icon column's Column can lay out normally.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: ac.accentFaint,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isWork ? Icons.work_outline : Icons.school_outlined,
                        size: 15,
                        color: ac.accent,
                      ),
                    ),
                    if (!isLast)
                      Expanded(
                        child: Container(
                          width: 1,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: ac.lineSoft,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: isLast ? 0 : 14, top: 3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.org,
                          style: AymaType.serif(size: 16, color: ac.fg),
                        ),
                        if (entry.titleOrDegree.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            entry.titleOrDegree,
                            // A restrained dotted underline is the only tell
                            // that Ayma isn't fully sure of this one — no
                            // percentage, no badge (§ provenance).
                            style: AymaType.sans(size: 13.5, color: ac.fgDim)
                                .copyWith(
                                  decoration: uncertain
                                      ? TextDecoration.underline
                                      : null,
                                  decorationStyle: TextDecorationStyle.dotted,
                                  decorationColor: ac.fgMute,
                                ),
                          ),
                        ],
                        if (entry.dateRange.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            entry.dateRange,
                            style: AymaType.mono(
                              size: 10.5,
                              color: ac.fgMute,
                            ).copyWith(letterSpacing: 0.6),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
