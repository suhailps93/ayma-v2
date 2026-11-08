/// Models for Practice Date (hackathon deliverable B) — the data the
/// simulator and debrief screens exchange with the backend `/practice/*` API.
///
/// Kept in its own `features/practice_date/` folder so the whole feature can be
/// lifted cleanly into the public hackathon repo.
library;

/// The simulated match's viewer-visible identity, returned by `/practice/start`.
/// Built only from the public profile — never any private/contact data.
class PracticePersona {
  const PracticePersona({
    required this.name,
    this.age,
    this.location = '',
    this.photoCount = 0,
    this.photoUrl,
  });

  final String name;
  final int? age;
  final String location;
  final int photoCount;

  /// The match's viewer-visible profile photo, shown in the voice simulator so
  /// the call looks like you're calling that person. Nullable/absent for
  /// seeded demo personas with no photo — callers fall back to the Ayma orb.
  final String? photoUrl;

  factory PracticePersona.fromMap(Map<String, dynamic> m) => PracticePersona(
        name: (m['name'] as String?) ?? '',
        age: (m['age'] as num?)?.toInt(),
        location: (m['location'] as String?) ?? '',
        photoCount: (m['photo_count'] as num?)?.toInt() ?? 0,
        photoUrl: m['photo_url'] as String?,
      );
}

/// Result of `POST /practice/start`.
class PracticeStart {
  const PracticeStart({
    required this.sessionId,
    required this.persona,
    required this.banner,
  });

  final String sessionId;
  final PracticePersona persona;

  /// The persistent "this is a simulation, not the real person" line.
  final String banner;

  factory PracticeStart.fromMap(Map<String, dynamic> m) => PracticeStart(
        sessionId: (m['session_id'] as String?) ?? '',
        persona: PracticePersona.fromMap(
            (m['persona'] as Map<String, dynamic>?) ?? const {}),
        banner: (m['banner'] as String?) ?? '',
      );
}

/// Result of `POST /practice/chat` — the match's in-character reply plus an
/// optional live coach nudge. [usageCapped] is true when the user is out of
/// credits (HTTP 402).
class PracticeTurn {
  const PracticeTurn({
    this.reply = '',
    this.coachHint = '',
    this.usageCapped = false,
  });

  final String reply;
  final String coachHint;
  final bool usageCapped;

  factory PracticeTurn.fromMap(Map<String, dynamic> m) => PracticeTurn(
        reply: (m['reply'] as String?) ?? '',
        coachHint: (m['coach_hint'] as String?) ?? '',
        usageCapped: m['usage_capped'] == true,
      );
}

/// Result of `POST /practice/voice/start` (hackathon B) — a practice VOICE
/// session seeded with the simulated persona. Carries the practice session id
/// (so the client can fetch the debrief after the call), the persona identity
/// for the simulator header, and the LiveKit credentials the existing voice
/// pipeline connects with. [usageCapped] is true when the user is out of
/// credits.
class PracticeVoiceSession {
  const PracticeVoiceSession({
    required this.sessionId,
    required this.persona,
    required this.banner,
    required this.livekitUrl,
    required this.livekitToken,
    this.usageCapped = false,
  });

  final String sessionId;
  final PracticePersona persona;
  final String banner;
  final String livekitUrl;
  final String livekitToken;
  final bool usageCapped;

  factory PracticeVoiceSession.fromMap(Map<String, dynamic> m) {
    final lk = (m['livekit'] as Map<String, dynamic>?) ?? const {};
    return PracticeVoiceSession(
      sessionId: (m['session_id'] as String?) ?? '',
      persona: PracticePersona.fromMap(
          (m['persona'] as Map<String, dynamic>?) ?? const {}),
      banner: (m['banner'] as String?) ?? '',
      livekitUrl: (lk['url'] as String?) ?? '',
      livekitToken: (lk['token'] as String?) ?? '',
      usageCapped: m['usage_capped'] == true,
    );
  }
}

/// Result of `POST /practice/debrief`.
class PracticeDebrief {
  const PracticeDebrief({
    this.whatWorked = const [],
    this.suggestedNextLines = const [],
    this.avoid = const [],
    this.empty = false,
  });

  final List<String> whatWorked;
  final List<String> suggestedNextLines;
  final List<String> avoid;

  /// True when the practice captured no conversation to review — the
  /// server returns empty sections instead of inventing feedback from
  /// nothing. The screen says so plainly rather than showing blank
  /// sections under a "here is how it went" header.
  final bool empty;

  static List<String> _strings(dynamic v) =>
      (v as List?)?.map((e) => e.toString()).toList() ?? const [];

  factory PracticeDebrief.fromMap(Map<String, dynamic> m) => PracticeDebrief(
        whatWorked: _strings(m['what_worked']),
        suggestedNextLines: _strings(m['suggested_next_lines']),
        avoid: _strings(m['avoid']),
        empty: m['empty'] == true,
      );
}
