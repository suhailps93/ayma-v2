import 'package:ayma_flutter/widgets/message_timestamp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatMessageTime', () {
    test('formats 12:00 AM (midnight)', () {
      final dt = DateTime(2026, 10, 31, 0, 0);
      expect(formatMessageTime(dt), '12:00 AM');
    });

    test('formats 12:05 AM', () {
      final dt = DateTime(2026, 10, 31, 0, 5);
      expect(formatMessageTime(dt), '12:05 AM');
    });

    test('formats 9:41 AM', () {
      final dt = DateTime(2026, 10, 31, 9, 41);
      expect(formatMessageTime(dt), '9:41 AM');
    });

    test('formats 12:00 PM (noon)', () {
      final dt = DateTime(2026, 10, 31, 12, 0);
      expect(formatMessageTime(dt), '12:00 PM');
    });

    test('formats 1:15 PM', () {
      final dt = DateTime(2026, 10, 31, 13, 15);
      expect(formatMessageTime(dt), '1:15 PM');
    });

    test('formats 11:59 PM', () {
      final dt = DateTime(2026, 10, 31, 23, 59);
      expect(formatMessageTime(dt), '11:59 PM');
    });
  });

  group('formatDateDivider', () {
    final baseNow = DateTime(2026, 10, 31, 14, 0); // Saturday, Oct 31, 2026

    test('returns "Today" for same calendar day', () {
      final dt = DateTime(2026, 10, 31, 9, 30);
      expect(formatDateDivider(dt, now: baseNow), 'Today');
    });

    test('returns "Yesterday" for 1 day before', () {
      final dt = DateTime(2026, 10, 30, 23, 50);
      expect(formatDateDivider(dt, now: baseNow), 'Yesterday');
    });

    test('returns weekday name within last 7 days (2 days ago)', () {
      // 2 days ago: Thursday, Oct 29, 2026
      final dt = DateTime(2026, 10, 29, 10, 0);
      expect(formatDateDivider(dt, now: baseNow), 'Thursday');
    });

    test('returns weekday name within last 7 days (6 days ago)', () {
      // 6 days ago: Sunday, Oct 25, 2026
      final dt = DateTime(2026, 10, 25, 18, 0);
      expect(formatDateDivider(dt, now: baseNow), 'Sunday');
    });

    test('returns full date for 7 days ago', () {
      // 7 days ago: Saturday, Oct 24, 2026
      final dt = DateTime(2026, 10, 24, 12, 0);
      expect(formatDateDivider(dt, now: baseNow), 'Oct 24, 2026');
    });

    test('returns full date for older dates (e.g. Oct 17, 2026)', () {
      final dt = DateTime(2026, 10, 17, 10, 15);
      expect(formatDateDivider(dt, now: baseNow), 'Oct 17, 2026');
    });
  });

  group('shouldShowDateDivider', () {
    test('returns false if currentDate is null', () {
      expect(shouldShowDateDivider(DateTime(2026, 10, 30), null), isFalse);
      expect(shouldShowDateDivider(null, null), isFalse);
    });

    test('returns true if prevDate is null and currentDate is non-null', () {
      expect(shouldShowDateDivider(null, DateTime(2026, 10, 30)), isTrue);
    });

    test('returns false if both are on the same calendar day', () {
      final d1 = DateTime(2026, 10, 30, 9, 0);
      final d2 = DateTime(2026, 10, 30, 15, 30);
      expect(shouldShowDateDivider(d1, d2), isFalse);
    });

    test('returns true if dates fall on different calendar days', () {
      final d1 = DateTime(2026, 10, 30, 23, 59);
      final d2 = DateTime(2026, 10, 31, 0, 1);
      expect(shouldShowDateDivider(d1, d2), isTrue);
    });
  });

  group('DateDividerChip widget', () {
    testWidgets('renders chip label with correct styling', (tester) async {
      final date = DateTime(2026, 10, 31, 10, 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DateDividerChip(date: date, now: DateTime(2026, 10, 31, 12, 0)),
          ),
        ),
      );

      expect(find.text('Today'), findsOneWidget);
    });
  });
}
