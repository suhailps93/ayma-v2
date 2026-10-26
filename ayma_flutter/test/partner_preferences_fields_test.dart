import 'package:ayma_flutter/widgets/partner_preferences_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 25);

  test('default age range is the user age -5 to +8', () {
    final r = defaultPartnerAgeRange(DateTime(1996, 5, 4), now: now); // 30
    expect(r.start, 25);
    expect(r.end, 38);
  });

  test('default age range never goes below the 18 floor', () {
    final r = defaultPartnerAgeRange(DateTime(2007, 1, 1), now: now); // 19
    expect(r.start, 18);
    expect(r.end, 27);
  });

  test('a birthday later this year does not count yet; no birthdate -> full',
      () {
    expect(defaultPartnerAgeRange(DateTime(1996, 12, 1), now: now).start, 24);
    final full = defaultPartnerAgeRange(null, now: now);
    expect(full.start, 18);
    expect(full.end, 99);
  });
}
