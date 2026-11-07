/// The plan on an Ayma date-plan card in a DM thread (PayPal hackathon).
///
/// The card message carries a `date_plan` map that the backend state
/// machine updates in place: proposed -> one approved -> both approved
/// -> paying -> reservation confirmed. Approvals and payments are keyed
/// by user id, one entry per person in the thread.
class DatePlan {
  const DatePlan({
    required this.status,
    required this.placeName,
    required this.placeKind,
    required this.reason,
    required this.timeLabel,
    required this.startsAt,
    required this.totalCents,
    required this.halfCents,
    required this.currency,
    required this.approvals,
    required this.payments,
    required this.revision,
    required this.paypalStubbed,
    this.confirmationNumber = '',
  });

  final String status; // proposed | partially_approved | both_approved | paying | confirmed
  final String placeName;
  final String placeKind;
  final String reason;
  final String timeLabel;
  final String startsAt;
  final int totalCents;
  final int halfCents;
  final String currency;
  final Map<String, bool> approvals;
  final Map<String, DatePlanPayment> payments;
  final int revision;
  final bool paypalStubbed;
  final String confirmationNumber;

  bool get isConfirmed => status == 'confirmed';

  bool approvedBy(String uid) => approvals[uid] == true;

  DatePlanPayment? paymentFor(String uid) => payments[uid];

  bool get bothApproved =>
      status == 'both_approved' || status == 'paying' || isConfirmed;

  /// What [uid] still owes: their payment amount while it is pending,
  /// else their half of the total before payments exist.
  int owedCentsFor(String uid) =>
      payments[uid]?.amountCents ?? halfCents;

  String get totalLabel => _money(totalCents);
  String halfLabelFor(String uid) => _money(owedCentsFor(uid));

  static String _money(int cents) =>
      '\$${(cents / 100).toStringAsFixed(2)}';

  /// The plain-language status line shown at the top of the card.
  String statusLabel(String myUid) {
    switch (status) {
      case 'proposed':
        return 'Waiting for both of you to approve';
      case 'partially_approved':
        return approvedBy(myUid)
            ? 'You approved — waiting for them'
            : 'They approved — waiting for you';
      case 'both_approved':
        return 'Both approved — ready to pay';
      case 'paying':
        final paid = payments.values.where((p) => p.isPaid).length;
        return paid == 0
            ? 'Both approved — waiting for both halves to be paid'
            : 'One half paid — waiting for the other half';
      case 'confirmed':
        return 'Reservation confirmed';
      default:
        return status;
    }
  }

  static DatePlan? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final place = raw['place_name'] as String? ?? '';
    if (place.isEmpty) return null;
    final approvals = <String, bool>{};
    final rawApprovals = raw['approvals'];
    if (rawApprovals is Map) {
      for (final e in rawApprovals.entries) {
        approvals['${e.key}'] = e.value == true;
      }
    }
    final payments = <String, DatePlanPayment>{};
    final rawPayments = raw['payments'];
    if (rawPayments is Map) {
      for (final e in rawPayments.entries) {
        final p = DatePlanPayment.tryParse(e.value);
        if (p != null) payments['${e.key}'] = p;
      }
    }
    final reservation = raw['reservation'];
    return DatePlan(
      status: raw['status'] as String? ?? 'proposed',
      placeName: place,
      placeKind: raw['place_kind'] as String? ?? '',
      reason: raw['reason'] as String? ?? '',
      timeLabel: raw['time_label'] as String? ?? '',
      startsAt: raw['starts_at'] as String? ?? '',
      totalCents: (raw['total_cents'] as num?)?.toInt() ?? 0,
      halfCents: (raw['half_cents'] as num?)?.toInt() ?? 0,
      currency: raw['currency'] as String? ?? 'USD',
      approvals: approvals,
      payments: payments,
      revision: (raw['revision'] as num?)?.toInt() ?? 1,
      paypalStubbed: raw['paypal_stubbed'] as bool? ?? false,
      confirmationNumber: reservation is Map
          ? (reservation['confirmation_number'] as String? ?? '')
          : '',
    );
  }
}

/// One person half of the split PayPal charge.
class DatePlanPayment {
  const DatePlanPayment({
    required this.orderId,
    required this.approveUrl,
    required this.amountCents,
    required this.status,
    this.captureId = '',
  });

  final String orderId;
  final String approveUrl;
  final int amountCents;
  final String status; // pending | paid
  final String captureId;

  bool get isPaid => status == 'paid';

  String get amountLabel =>
      '\$${(amountCents / 100).toStringAsFixed(2)}';

  static DatePlanPayment? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return DatePlanPayment(
      orderId: raw['order_id'] as String? ?? '',
      approveUrl: raw['approve_url'] as String? ?? '',
      amountCents: (raw['amount_cents'] as num?)?.toInt() ?? 0,
      status: raw['status'] as String? ?? 'pending',
      captureId: raw['capture_id'] as String? ?? '',
    );
  }
}
