import 'living_report.dart';

/// One analysed photo in the card's pool: its loadable [url], its
/// accessibility [label], and a stable [id] (the Storage path) used as the
/// durable key for hiding it from the card. [id] falls back to [url] when the
/// report carried no explicit id (both are stable).
class CardPhoto {
  const CardPhoto({required this.url, required this.label, required this.id});

  final String url;
  final String label;
  final String id;
}

/// What the shareable Appearance report card shows, read off the caller's own
/// Appearance [LivingReport] (`report_adapters.appearance_blocks`): the
/// analysed photos, the Face and Body scores with their verdicts, and the
/// positive findings only. Also carries the recommendations for the private
/// "What to do next" list under the card, which is never drawn on the card.
///
/// [pool] is the full ordered set of analysed photos (more than the card can
/// show); [hidden] is the ids the user has removed from the card. [visible]
/// is what the card actually draws — the pool minus the hidden ids, capped at
/// [maxPhotos] — so removing one shown photo slides the next pooled photo into
/// its place, and an exhausted pool simply shows fewer (down to zero).
///
/// [fromReport] returns null when the card can't be made honestly: either
/// score is missing, or no analysed photo resolved. The screen then shows the
/// normal report only.
class AppearanceCardData {
  const AppearanceCardData({
    required this.pool,
    required this.hidden,
    required this.faceScore,
    required this.faceVerdict,
    required this.bodyScore,
    required this.bodyVerdict,
    required this.standOuts,
    required this.nextSteps,
  });

  static const maxPhotos = 4;
  static const maxStandOuts = 4;

  /// Every analysed photo available to the card, ordered best/most-relevant
  /// first: the face photo, then the body photo(s), then the rest.
  final List<CardPhoto> pool;

  /// Ids ([CardPhoto.id]) the user has removed from the card. Card-only — the
  /// underlying photo and its analysis are untouched.
  final Set<String> hidden;

  /// The photos the card draws: [pool] minus [hidden], capped at [maxPhotos].
  List<CardPhoto> get visible => [
    for (final p in pool)
      if (!hidden.contains(p.id)) p,
  ].take(maxPhotos).toList();

  /// Face photo first, then the body photo(s), then other analysed photos;
  /// never more than [maxPhotos]. Derived from [visible].
  List<String> get photoUrls => [for (final p in visible) p.url];

  /// Accessibility label per visible photo, parallel to [photoUrls].
  List<String> get photoLabels => [for (final p in visible) p.label];

  /// This card with a different [hidden] set (same pool, scores, findings).
  AppearanceCardData withHidden(Set<String> next) => AppearanceCardData(
    pool: pool,
    hidden: next,
    faceScore: faceScore,
    faceVerdict: faceVerdict,
    bodyScore: bodyScore,
    bodyVerdict: bodyVerdict,
    standOuts: standOuts,
    nextSteps: nextSteps,
  );

  final String faceScore;
  final String faceVerdict;
  final String bodyScore;
  final String bodyVerdict;

  /// Up to [maxStandOuts] strengths, alternating Face and Body.
  final List<String> standOuts;

  /// `(category label, text)` recommendations, Face then Body. Private.
  final List<(String, String)> nextSteps;

  /// Strength text that must never reach a shared image even if a model put
  /// it in a strength: body fat, weight, the worst feature.
  static final _sensitive = RegExp(
    r'body[\s-]*fat|%|\bweight\b|\bworst\b',
    caseSensitive: false,
  );

  static AppearanceCardData? fromReport(LivingReport report) {
    final blocks = [for (final s in report.sections) ...s.blocks];
    ReportBlock? stat(String id) {
      for (final b in blocks) {
        if (b.blockId == id && b.type == kBlockStat) return b;
      }
      return null;
    }

    final face = stat('face');
    final body = stat('body');
    final faceScore = _score(face?.value);
    final bodyScore = _score(body?.value);
    if (faceScore == null || bodyScore == null) return null;

    final pool = <CardPhoto>[];
    final seen = <String>{};
    const kinds = {
      'face:': 'Your face photo',
      'body:': 'Your body photo',
      'attr:': 'Your photo',
    };
    for (final prefix in kinds.keys) {
      for (final b in blocks) {
        if (!b.blockId.startsWith(prefix)) continue;
        final found = b.type == kBlockPhoto
            ? [(b.url, b.photoId)]
            : b.type == kBlockPhotoGrid
            ? [
                for (final p in b.photos)
                  (p['url'] as String? ?? '', p['photo_id'] as String? ?? ''),
              ]
            : const <(String, String)>[];
        for (final (u, pid) in found) {
          // The id (Storage path) is the durable key; it falls back to the
          // url (also stable) so an older report with no id still de-dupes
          // and hides correctly.
          final id = pid.isNotEmpty ? pid : u;
          if (u.isNotEmpty && seen.add(id)) {
            pool.add(CardPhoto(url: u, label: kinds[prefix]!, id: id));
          }
        }
      }
    }
    if (pool.isEmpty) return null;

    List<String> strengths(String prefix) => [
      for (final b in blocks)
        if (b.type == kBlockFact &&
            b.tag == 'strength' &&
            b.blockId.startsWith('$prefix:strength:') &&
            b.text.trim().isNotEmpty &&
            !_sensitive.hasMatch(b.text))
          b.text.trim(),
    ];
    final faceS = strengths('face');
    final bodyS = strengths('body');
    final standOuts = <String>[];
    for (
      var i = 0;
      standOuts.length < maxStandOuts && (i < faceS.length || i < bodyS.length);
      i++
    ) {
      if (i < faceS.length) standOuts.add(faceS[i]);
      if (i < bodyS.length && standOuts.length < maxStandOuts) {
        standOuts.add(bodyS[i]);
      }
    }

    final nextSteps = [
      for (final prefix in const ['face', 'body'])
        for (final b in blocks)
          if (isRecommendation(b) &&
              b.blockId.startsWith('$prefix:') &&
              b.text.trim().isNotEmpty)
            (_category(b.tag), b.text.trim()),
    ];

    // The owner's hidden ids come from the report meta; keep only ids still
    // in the pool so a stale one (a photo since deleted or re-analysed out)
    // never silently shrinks the card.
    final poolIds = {for (final p in pool) p.id};
    final hidden = {
      for (final id in report.meta.cardHiddenPhotos)
        if (poolIds.contains(id)) id,
    };

    return AppearanceCardData(
      pool: pool,
      hidden: hidden,
      faceScore: faceScore,
      faceVerdict: _verdict(face!),
      bodyScore: bodyScore,
      bodyVerdict: _verdict(body!),
      standOuts: standOuts,
      nextSteps: nextSteps,
    );
  }

  /// A face/body recommendation fact: shown only in "What to do next".
  static bool isRecommendation(ReportBlock b) =>
      b.type == kBlockFact && RegExp(r'^(face|body):reco:').hasMatch(b.blockId);

  /// "6.3" for a 0-10 score; a whole number drops the ".0".
  static String? _score(Object? v) {
    final n = v is num ? v : num.tryParse('${v ?? ''}');
    if (n == null) return null;
    return n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);
  }

  /// The stat's verdict ("Above average"); the stat label falls back to
  /// "Score" when there's none, which is not a verdict.
  static String _verdict(ReportBlock b) {
    final v = b.basis.trim().isNotEmpty ? b.basis.trim() : b.label.trim();
    return v.toLowerCase() == 'score' ? '' : v;
  }

  static const _categoryLabels = {
    'beard_grooming': 'Grooming',
    'hair_styling': 'Hair',
    'under_eye': 'Under-eye',
  };

  static String _category(String tag) {
    final t = tag.trim();
    if (t.isEmpty) return 'Next step';
    final known = _categoryLabels[t];
    if (known != null) return known;
    final words = t.replaceAll('_', ' ');
    return words[0].toUpperCase() + words.substring(1);
  }
}
