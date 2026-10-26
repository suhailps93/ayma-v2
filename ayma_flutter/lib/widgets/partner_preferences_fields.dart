import 'package:flutter/material.dart';

import '../theme.dart';

const partnerAgeFloor = 18.0;
const partnerAgeCeiling = 99.0;

/// Default distance when the user hasn't chosen: 50 miles ("anywhere" is never
/// assumed).
const defaultDistancePref = '50';

/// `distance_pref` values (miles, or `anywhere`) and their labels.
const distancePrefOptions = <String, String>{
  '10': '10 miles',
  '25': '25 miles',
  '50': '50 miles',
  '100': '100 miles',
  'anywhere': 'Anywhere is fine',
};

/// A starting partner age range derived from the user's own age (their age
/// minus 5 to plus 8), never below the 18 floor and never above the ceiling.
/// Without a birthdate it falls back to the full 18–99 range.
RangeValues defaultPartnerAgeRange(DateTime? birthdate, {DateTime? now}) {
  if (birthdate == null) {
    return const RangeValues(partnerAgeFloor, partnerAgeCeiling);
  }
  final today = now ?? DateTime.now();
  var age = today.year - birthdate.year;
  if (today.month < birthdate.month ||
      (today.month == birthdate.month && today.day < birthdate.day)) {
    age--;
  }
  return RangeValues(
    (age - 5).clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
    (age + 8).clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
  );
}

/// Partner age range slider (18 floor) plus the distance radius selector with
/// an explicit "Anywhere is fine" option — shared by preboarding and Edit
/// profile.
class PartnerPreferencesFields extends StatelessWidget {
  const PartnerPreferencesFields({
    super.key,
    required this.ages,
    required this.distance,
    required this.onAgesChanged,
    required this.onDistanceChanged,
  });

  final RangeValues ages;
  final String distance;
  final ValueChanged<RangeValues> onAgesChanged;
  final ValueChanged<String> onDistanceChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text,
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label('Partner age range: ${ages.start.round()}–${ages.end.round()}'),
        RangeSlider(
          key: const Key('profile_age_range'),
          values: ages,
          min: partnerAgeFloor,
          max: partnerAgeCeiling,
          divisions: (partnerAgeCeiling - partnerAgeFloor).round(),
          labels: RangeLabels(
              '${ages.start.round()}', '${ages.end.round()}'),
          onChanged: onAgesChanged,
        ),
        const SizedBox(height: 12),
        label('How far would you go for a match?'),
        Wrap(
          spacing: 8,
          children: [
            for (final e in distancePrefOptions.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: distance == e.key,
                onSelected: (_) => onDistanceChanged(e.key),
              ),
          ],
        ),
      ],
    );
  }
}
