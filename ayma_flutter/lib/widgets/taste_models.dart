/// Models for the "Taste match · powered by Qloo" card — the shared taste
/// overlap between two people. Used both on the AI Date Simulation result
/// (`POST /taste/pair`) and as a section embedded in the match report
/// (`GET /match/{id}` → `taste`).
library;

/// One per-domain overlap read (music, film, dining), 0–100.
class TasteDomain {
  const TasteDomain({required this.domain, required this.score});

  final String domain;
  final int score;

  factory TasteDomain.fromMap(Map<String, dynamic> m) => TasteDomain(
        domain: (m['domain'] as String?) ?? '',
        score: (m['score'] as num?)?.toInt() ?? 0,
      );
}

/// A date idea both people would enjoy; [address] is null when unknown.
class TasteDateIdea {
  const TasteDateIdea({
    required this.name,
    this.kind = '',
    this.why = '',
    this.address,
  });

  final String name;
  final String kind;
  final String why;
  final String? address;

  factory TasteDateIdea.fromMap(Map<String, dynamic> m) => TasteDateIdea(
        name: (m['name'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? '',
        why: (m['why'] as String?) ?? '',
        address: m['address'] as String?,
      );
}

/// Result of `POST /taste/pair`: the pair's taste overlap. [isSample] is true
/// when the backend served fixture data rather than live Qloo results.
class TasteMatch {
  const TasteMatch({
    this.isSample = false,
    this.score = 0,
    this.scoreLabel = '',
    this.summary = '',
    this.shared = const [],
    this.domains = const [],
    this.dateIdeas = const [],
  });

  final bool isSample;
  final int score;
  final String scoreLabel;
  final String summary;
  final List<String> shared;
  final List<TasteDomain> domains;
  final List<TasteDateIdea> dateIdeas;

  factory TasteMatch.fromMap(Map<String, dynamic> m) => TasteMatch(
        isSample: m['source'] == 'fixture',
        score: (m['score'] as num?)?.toInt() ?? 0,
        scoreLabel: (m['score_label'] as String?) ?? '',
        summary: (m['summary'] as String?) ?? '',
        shared: ((m['shared'] as List?) ?? const [])
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toList(),
        domains: ((m['domains'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TasteDomain.fromMap)
            .where((d) => d.domain.isNotEmpty)
            .toList(),
        dateIdeas: ((m['date_ideas'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TasteDateIdea.fromMap)
            .where((i) => i.name.isNotEmpty)
            .toList(),
      );
}

/// `POST /taste/pair` answered 404 `no_taste`: one of the two people has no
/// public Taste page. [message] is the backend's user-facing hint.
class NoTasteException implements Exception {
  const NoTasteException(this.message);

  final String message;

  @override
  String toString() => 'NoTasteException: $message';
}

/// The resolved outcome of a taste match: either a [match], or a short [note]
/// to show in its place (the no-Taste-page hint, or an "unavailable" line).
/// Used by [TasteMatchCard] on both the date-sim result and the match report.
class TasteMatchLoad {
  const TasteMatchLoad.match(TasteMatch this.match) : note = null;
  const TasteMatchLoad.note(String this.note) : match = null;

  final TasteMatch? match;
  final String? note;

  /// Builds the section from a match report's embedded `taste` value
  /// (`GET /match/{id}` → `taste`): `null`/non-map ⇒ no section; a
  /// `{"status": "no_taste", "message": …}` marker ⇒ the empty-state note;
  /// otherwise the full taste match.
  static TasteMatchLoad? fromReportValue(Object? v) {
    if (v is! Map) return null;
    final map = v.cast<String, dynamic>();
    if (map['status'] == 'no_taste') {
      final msg = map['message'];
      return TasteMatchLoad.note(msg is String && msg.isNotEmpty
          ? msg
          : 'Add a public "Taste" page (e.g. "Music: …") to see a taste match.');
    }
    return TasteMatchLoad.match(TasteMatch.fromMap(map));
  }
}
