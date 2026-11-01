// R2-C3 regression (root cause): a stored date of birth must bind back into
// the read model no matter which layer wrote it. The Flutter client writes a
// Firestore Timestamp, but the server (set_profile_field voice tool, seeded
// accounts — functions/.../mcp_tools.py, completeness.py) writes an ISO-8601
// String like "1990-01-01". The old `fromMap` only accepted Timestamp, so a
// server-written DOB came back null and Edit profile showed "Pick a date"
// even though the public profile showed the age.
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> base(Object? birthdate) => {
        'name': 'Alex',
        'first_name': 'Alex',
        'last_name': 'Rivera',
        'gender': 'Man',
        'interested_in': ['Women'],
        'location': 'San Jose',
        'birthdate': birthdate,
      };

  test('parses an ISO-8601 String birthdate (server / seeded accounts)', () {
    final p = ProfileData.fromMap(base('1990-01-01'));
    expect(p.birthdate, DateTime(1990, 1, 1));
  });

  test('still parses a Firestore Timestamp birthdate (Flutter client)', () {
    final ts = Timestamp.fromDate(DateTime(1988, 7, 15, 12));
    final p = ProfileData.fromMap(base(ts));
    expect(p.birthdate, DateTime(1988, 7, 15, 12));
  });

  test('parses an epoch-millis int birthdate', () {
    final millis = DateTime.utc(1995, 3, 9).millisecondsSinceEpoch;
    final p = ProfileData.fromMap(base(millis));
    expect(p.birthdate, DateTime.fromMillisecondsSinceEpoch(millis));
  });

  test('missing / empty / unparseable birthdate stays null (no crash)', () {
    expect(ProfileData.fromMap(base(null)).birthdate, isNull);
    expect(ProfileData.fromMap(base('')).birthdate, isNull);
    expect(ProfileData.fromMap(base('not-a-date')).birthdate, isNull);
  });
}
