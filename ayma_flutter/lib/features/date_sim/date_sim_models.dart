/// Models for AI Date Simulation (hackathon flagship) — the data the simulation
/// screen exchanges with the backend `POST /date-sim`.
///
/// Reuses [PracticePersona] (the match's viewer-visible identity) from the
/// Practice Date feature, since both are built from the same public profile.
library;

import '../practice_date/practice_models.dart';

/// One message in the simulated transcript. [fromYou] marks the current user's
/// persona (right-aligned, "mine"); otherwise it's the match's persona.
class DateSimMessage {
  const DateSimMessage({required this.fromYou, required this.text});

  final bool fromYou;
  final String text;

  factory DateSimMessage.fromMap(Map<String, dynamic> m) => DateSimMessage(
        fromYou: (m['from'] as String?) == 'you',
        text: (m['text'] as String?) ?? '',
      );
}

/// Result of `POST /date-sim` — the simulated conversation plus the
/// compatibility read (a 0–100 [score], a short [scoreLabel] and a [summary]).
/// [usageCapped] is true when the user is out of credits (HTTP 402, or the
/// conversation was cut short mid-run).
class DateSimResult {
  const DateSimResult({
    this.persona = const PracticePersona(name: ''),
    this.banner = '',
    this.messages = const [],
    this.score = 0,
    this.scoreLabel = '',
    this.summary = '',
    this.moderationFlagged = false,
    this.usageCapped = false,
  });

  final PracticePersona persona;

  /// The persistent "Simulated — not sent to `<name>`" line.
  final String banner;
  final List<DateSimMessage> messages;

  /// 0–100 compatibility read for the pair, grounded in the simulated chat.
  final int score;
  final String scoreLabel;
  final String summary;
  final bool moderationFlagged;
  final bool usageCapped;

  /// The out-of-credits sentinel (HTTP 402) — nothing was simulated.
  const DateSimResult.capped() : this(usageCapped: true);

  factory DateSimResult.fromMap(Map<String, dynamic> m) => DateSimResult(
        persona: PracticePersona.fromMap(
            (m['persona'] as Map<String, dynamic>?) ?? const {}),
        banner: (m['banner'] as String?) ?? '',
        messages: ((m['transcript'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DateSimMessage.fromMap)
            .toList(),
        score: (m['score'] as num?)?.toInt() ?? 0,
        scoreLabel: (m['score_label'] as String?) ?? '',
        summary: (m['summary'] as String?) ?? '',
        moderationFlagged:
            ((m['moderation'] as Map<String, dynamic>?)?['flagged']) == true,
        usageCapped: m['usage_capped'] == true,
      );
}
