/// Models for AI Date Simulation (hackathon flagship) — the live simulation
/// state the screen reads from Firestore while the backend (`POST /date-sim`)
/// generates it.
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
    fromYou: (m['speaker'] as String?) == 'you',
    text: (m['text'] as String?) ?? '',
  );
}

enum DateSimStatus { running, done, error }

/// The live state of one simulation, read from the sim's Firestore doc
/// (`users/{uid}/date_sims/{simId}`, backend-written). The compatibility read
/// is a 0–100 [score], a short [scoreLabel] and a [summary]. [usageCapped] is
/// true when the user ran out of credits mid-run.
class DateSimDoc {
  const DateSimDoc({
    this.status = DateSimStatus.running,
    this.persona = const PracticePersona(name: ''),
    this.banner = '',
    this.maxMessages = 0,
    this.score = 0,
    this.scoreLabel = '',
    this.summary = '',
    this.moderationFlagged = false,
    this.usageCapped = false,
    this.errorMessage = '',
  });

  final DateSimStatus status;
  final PracticePersona persona;

  /// The persistent "Simulated — not sent to `<name>`" line.
  final String banner;
  final int maxMessages;
  final int score;
  final String scoreLabel;
  final String summary;
  final bool moderationFlagged;
  final bool usageCapped;
  final String errorMessage;

  bool get hasVerdict =>
      scoreLabel.isNotEmpty || summary.isNotEmpty || score > 0;

  factory DateSimDoc.fromMap(Map<String, dynamic> m) {
    final verdict = (m['verdict'] as Map?)?.cast<String, dynamic>() ?? const {};
    final err = (m['error'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DateSimDoc(
      status: switch (m['status']) {
        'done' => DateSimStatus.done,
        'error' => DateSimStatus.error,
        _ => DateSimStatus.running,
      },
      persona: PracticePersona.fromMap(
        (m['persona'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      banner: (m['banner'] as String?) ?? '',
      maxMessages: (m['max_messages'] as num?)?.toInt() ?? 0,
      score: (verdict['score'] as num?)?.toInt() ?? 0,
      scoreLabel: (verdict['score_label'] as String?) ?? '',
      summary: (verdict['summary'] as String?) ?? '',
      moderationFlagged: ((m['moderation'] as Map?)?['flagged']) == true,
      usageCapped: m['usage_capped'] == true,
      errorMessage: (err['message'] as String?) ?? '',
    );
  }
}
