/// The 18+ rule, in one place. Ayma is strictly 18 and over (Terms); the
/// server is authoritative (`functions/bootstrap/age_gate.py`) — this only
/// keeps the UI honest and gives under-18 entries a hard stop.
class AgeGate {
  const AgeGate._();

  static const minAge = 18;

  static const mustBeAdultMessage = 'You must be 18 or older to use Ayma.';

  /// Whole-year age on [now] (local calendar date), leap-year correct: a
  /// Feb 29 birthday is reached on Mar 1 in a common year.
  static int ageOn(DateTime birthdate, DateTime now) {
    var age = now.year - birthdate.year;
    if (now.month < birthdate.month ||
        (now.month == birthdate.month && now.day < birthdate.day)) {
      age--;
    }
    return age;
  }

  static bool isAdult(DateTime birthdate, {DateTime? now}) =>
      ageOn(birthdate, now ?? DateTime.now()) >= minAge;

  /// The latest birthdate that still makes someone 18 today — the upper bound
  /// for every date picker.
  static DateTime latestAdultBirthdate({DateTime? now}) {
    final n = now ?? DateTime.now();
    final year = n.year - minAge;
    final lastDay = DateTime(year, n.month + 1, 0).day;
    return DateTime(year, n.month, n.day > lastDay ? lastDay : n.day);
  }

  /// `YYYY-MM-DD`, the form the server's `/age-gate/declare` takes.
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Thrown by profile writes handed a birthdate under 18.
class UnderageBirthdateException implements Exception {
  const UnderageBirthdateException();

  @override
  String toString() => AgeGate.mustBeAdultMessage;
}
