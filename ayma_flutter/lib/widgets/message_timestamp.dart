import 'package:flutter/material.dart';

import '../theme.dart';

/// Formats a [DateTime] into a 12-hour WhatsApp-style time string (`h:mm AM/PM`),
/// using the device's local timezone.
String formatMessageTime(DateTime dt) {
  final local = dt.toLocal();
  final hour = local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = hour >= 12 ? 'PM' : 'AM';
  final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$h12:$minute $period';
}

/// Returns the number of calendar days between two dates (`from` minus `to`).
int _calendarDaysBetween(DateTime from, DateTime to) {
  final fromUtc = DateTime.utc(from.year, from.month, from.day);
  final toUtc = DateTime.utc(to.year, to.month, to.day);
  return fromUtc.difference(toUtc).inDays;
}

/// Formats a [DateTime] for a WhatsApp-style date divider chip:
/// - "Today" for today
/// - "Yesterday" for yesterday
/// - Weekday name (e.g. "Monday") within the last 7 days (2..6 days ago)
/// - Full date (e.g. "Oct 17, 2026") otherwise.
///
/// An optional [now] timestamp can be supplied (useful for deterministic tests).
String formatDateDivider(DateTime dt, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toLocal();
  final target = dt.toLocal();
  final diffDays = _calendarDaysBetween(current, target);

  if (diffDays == 0) {
    return 'Today';
  } else if (diffDays == 1) {
    return 'Yesterday';
  } else if (diffDays >= 2 && diffDays < 7) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return weekdays[target.weekday - 1];
  } else {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[target.month - 1]} ${target.day}, ${target.year}';
  }
}

/// Whether a date divider should be displayed before [currentDate] in a
/// chronological sequence of messages.
///
/// - Returns false if [currentDate] is null (no timestamp available; do not invent data).
/// - Returns true if [prevDate] is null (first dated message in thread).
/// - Returns true if [prevDate] and [currentDate] fall on different calendar days.
/// - Returns false if both fall on the same calendar day.
bool shouldShowDateDivider(DateTime? prevDate, DateTime? currentDate) {
  if (currentDate == null) return false;
  if (prevDate == null) return true;
  final prevLocal = prevDate.toLocal();
  final currentLocal = currentDate.toLocal();
  return prevLocal.year != currentLocal.year ||
      prevLocal.month != currentLocal.month ||
      prevLocal.day != currentLocal.day;
}

/// A centered pill chip displaying a date divider ("Today", "Yesterday",
/// weekday, or "Oct 17, 2026").
class DateDividerChip extends StatelessWidget {
  const DateDividerChip({super.key, required this.date, this.now});

  final DateTime date;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final label = formatDateDivider(date, now: now);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: ac.bgElev,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: ac.lineSoft, width: 0.5),
          ),
          child: Text(
            label,
            style: AymaType.sans(
              size: 11,
              color: ac.fgMute,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
