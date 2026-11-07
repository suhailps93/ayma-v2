import 'package:flutter/material.dart';

import '../services/date_plan.dart';
import '../theme.dart';

/// The Ayma date-plan card inside a DM thread.
///
/// Shows the place, the time, and the cost; an Approve button for each
/// person (each person approves for themselves, and the card shows who
/// has and has not); a way to reply with a suggested change instead;
/// and, once both have approved, each person PayPal half with its
/// pending / paid state. A confirmed card shows the booking
/// confirmation number.
class DatePlanCard extends StatelessWidget {
  const DatePlanCard({
    super.key,
    required this.plan,
    required this.myUid,
    required this.otherUid,
    required this.otherName,
    this.onApprove,
    this.onPay,
    this.onSuggest,
    this.busy = false,
  });

  final DatePlan plan;
  final String myUid;
  final String otherUid;
  final String otherName;
  final VoidCallback? onApprove;
  final VoidCallback? onPay;
  final VoidCallback? onSuggest;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final mineApproved = plan.approvedBy(myUid);
    final otherApproved = plan.approvedBy(otherUid);
    final myPayment = plan.paymentFor(myUid);
    final otherPayment = plan.paymentFor(otherUid);
    final canApprove = !plan.isConfirmed &&
        !mineApproved &&
        plan.status != 'paying' &&
        plan.status != 'both_approved';
    final canPay = !plan.isConfirmed &&
        myPayment != null &&
        !myPayment.isPaid &&
        (plan.status == 'paying' || plan.status == 'both_approved');
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
          if (plan.placeKind.isNotEmpty)
            Text(plan.placeKind,
                style: AymaType.sans(size: 13, color: ac.fgMute)),
          const SizedBox(height: 6),
          Text(plan.timeLabel,
              style: AymaType.sans(size: 14, color: ac.fg)),
          if (plan.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(plan.reason,
                style: AymaType.sans(size: 12, color: ac.fgMute)),
          ],
          const SizedBox(height: 8),
          Text(
            '${plan.totalLabel} total — ${plan.halfLabelFor(myUid)} each, '
            'split with PayPal',
            style: AymaType.sans(size: 13, color: ac.fg),
          ),
          const SizedBox(height: 10),
          Text(
            plan.statusLabel(myUid),
            key: const ValueKey('date-plan-status'),
            style: AymaType.sans(
                size: 13, color: ac.accent, weight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _personRow(ac, 'You', mineApproved, myPayment),
          _personRow(ac, otherName, otherApproved, otherPayment),
          if (plan.paypalStubbed && plan.payments.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'PayPal sandbox test mode — no real money moves.',
              style: AymaType.sans(size: 11, color: ac.fgMute),
            ),
          ],
          if (plan.isConfirmed &&
              plan.confirmationNumber.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Booking confirmation: ${plan.confirmationNumber}',
              key: const ValueKey('date-plan-confirmation'),
              style: AymaType.sans(
                  size: 13, color: ac.fg, weight: FontWeight.w600),
            ),
          ],
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
              if (canPay)
                FilledButton(
                  key: const ValueKey('date-plan-pay'),
                  onPressed: busy ? null : onPay,
                  child: Text('Pay my half ${myPayment.amountLabel}'),
                ),
              if (!plan.isConfirmed)
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

  Widget _personRow(AymaTokens ac, String name, bool approved,
      DatePlanPayment? payment) {
    final String state;
    if (payment != null) {
      state = payment.isPaid
          ? 'approved · paid ${payment.amountLabel}'
          : 'approved · payment pending';
    } else {
      state = approved ? 'approved' : 'not approved yet';
    }
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
            child: Text('$name — $state',
                style: AymaType.sans(size: 13, color: ac.fg)),
          ),
        ],
      ),
    );
  }
}
