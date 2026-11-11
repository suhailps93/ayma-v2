/// The plan on an Ayma date-plan card in a DM thread (payment-free).
///
/// The card message carries a `date_plan` map that the backend state
/// machine updates in place: proposed -> partially_approved ->
/// both_approved. `both_approved` is the terminal approved state the
/// "date moment" step-in reads. Approvals are keyed by user id, one
/// entry per person in the thread. The place carries a geographic anchor
/// (name + address, and lat/lng when the proposer supplied them) so the
/// step-in can match the user's arrival to it.
class DatePlan {
  const DatePlan({
    required this.status,
    required this.proposerUid,
    required this.placeName,
    required this.address,
    required this.lat,
    required this.lng,
    required this.timeLabel,
    required this.startsAt,
    required this.approvals,
    required this.revision,
    required this.momentFired,
  });

  final String status; // proposed | partially_approved | both_approved
  final String proposerUid;
  final String placeName;
  final String address;
  final double? lat;
  final double? lng;
  final String timeLabel;
  final String startsAt;
  final Map<String, bool> approvals;
  final int revision;
  final bool momentFired;

  bool approvedBy(String uid) => approvals[uid] == true;

  bool get bothApproved => status == 'both_approved';

  /// True when the place can be matched to a device location (coordinates).
  bool get hasCoords => lat != null && lng != null;

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
        return 'Both approved — the date is on';
      default:
        return status;
    }
  }

  static double? _coord(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String && raw.trim().isNotEmpty) return double.tryParse(raw);
    return null;
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
    return DatePlan(
      status: raw['status'] as String? ?? 'proposed',
      proposerUid: raw['proposer_uid'] as String? ?? '',
      placeName: place,
      address: raw['address'] as String? ?? '',
      lat: _coord(raw['lat']),
      lng: _coord(raw['lng']),
      timeLabel: raw['time_label'] as String? ?? '',
      startsAt: raw['starts_at'] as String? ?? '',
      approvals: approvals,
      revision: (raw['revision'] as num?)?.toInt() ?? 1,
      momentFired: raw['moment_fired'] as bool? ?? false,
    );
  }
}
