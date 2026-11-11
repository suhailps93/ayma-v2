import 'package:flutter/material.dart';

import '../services/date_plan.dart';
import '../theme.dart';

/// The Ayma date-plan card inside a DM thread (payment-free).
///
/// Shows the place (with its address) and the time; an Approve button for
/// each person (each approves for themselves, and the card shows who has
/// and has not); and a "Suggest a change" that revises the plan and
/// resets approvals. Once both approve, the card reads "the date is on".
class DatePlanCard extends StatelessWidget {
  const DatePlanCard({
    super.key,
    required this.plan,
    required this.myUid,
    required this.otherUid,
    required this.otherName,
    this.onApprove,
    this.onSuggest,
    this.busy = false,
  });

  final DatePlan plan;
  final String myUid;
  final String otherUid;
  final String otherName;
  final VoidCallback? onApprove;
  final VoidCallback? onSuggest;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final mineApproved = plan.approvedBy(myUid);
    final otherApproved = plan.approvedBy(otherUid);
    final canApprove = !mineApproved && !plan.bothApproved;
    return Container(
      key: const ValueKey('date-plan-card'),
      width: 280,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.event_available, size: 18, color: ac.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Ayma planned a date',
                  style: AymaType.sans(
                      size: 13, color: ac.fgMute, weight: FontWeight.w600),
                ),
              ),
              if (plan.revision > 1)
                Text('Updated plan',
                    style: AymaType.sans(size: 11, color: ac.fgMute)),
            ],
          ),
          const SizedBox(height: 8),
          Text(plan.placeName,
              style: AymaType.sans(
                  size: 17, color: ac.fg, weight: FontWeight.w700)),
          if (plan.address.isNotEmpty)
            Text(plan.address,
                style: AymaType.sans(size: 13, color: ac.fgMute)),
          if (plan.timeLabel.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(plan.timeLabel,
                style: AymaType.sans(size: 14, color: ac.fg)),
          ],
          const SizedBox(height: 10),
          Text(
            plan.statusLabel(myUid),
            key: const ValueKey('date-plan-status'),
            style: AymaType.sans(
                size: 13, color: ac.accent, weight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _personRow(ac, 'You', mineApproved),
          _personRow(ac, otherName, otherApproved),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canApprove)
                FilledButton(
                  key: const ValueKey('date-plan-approve'),
                  onPressed: busy ? null : onApprove,
                  child: const Text('Approve'),
                ),
              OutlinedButton(
                key: const ValueKey('date-plan-suggest'),
                onPressed: busy ? null : onSuggest,
                child: const Text('Suggest a change'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _personRow(AymaTokens ac, String name, bool approved) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            approved ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: approved ? ac.accent : ac.fgMute,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text('$name — ${approved ? 'approved' : 'not approved yet'}',
                style: AymaType.sans(size: 13, color: ac.fg)),
          ),
        ],
      ),
    );
  }
}
