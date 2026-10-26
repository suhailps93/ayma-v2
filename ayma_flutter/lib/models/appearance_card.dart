import 'living_report.dart';

/// What the shareable Appearance report card shows, read off the caller's own
/// Appearance [LivingReport] (`report_adapters.appearance_blocks`): the
/// analysed photos, the Face and Body scores with their verdicts, and the
/// positive findings only. Also carries the recommendations for the private
/// "What to do next" list under the card, which is never drawn on the card.
///
/// [fromReport] returns null when the card can't be made honestly: either
/// score is missing, or no analysed photo resolved. The screen then shows the
/// normal report only.
class AppearanceCardData {
  const AppearanceCardData({
    required this.photoUrls,
    required this.photoLabels,
    required this.faceScore,
    required this.faceVerdict,
    required this.bodyScore,
    required this.bodyVerdict,
    required this.standOuts,
    required this.nextSteps,
  });

  static const maxPhotos = 4;
  static const maxStandOuts = 4;

  /// Face photo first, then the body photo(s), then other analysed photos;
  /// never more than [maxPhotos].
  final List<String> photoUrls;

  /// Accessibility label per photo, parallel to [photoUrls].
  final List<String> photoLabels;
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

    final urls = <String>[];
    final labels = <String>[];
    const kinds = {
      'face:': 'Your face photo',
      'body:': 'Your body photo',
      'attr:': 'Your photo',
    };
    for (final prefix in kinds.keys) {
      for (final b in blocks) {
        if (!b.blockId.startsWith(prefix)) continue;
        final found = b.type == kBlockPhoto
            ? [b.url]
            : b.type == kBlockPhotoGrid
            ? [for (final p in b.photos) (p['url'] as String? ?? '')]
            : const <String>[];
        for (final u in found) {
          if (u.isNotEmpty && !urls.contains(u)) {
            urls.add(u);
            labels.add(kinds[prefix]!);
          }
        }
      }
    }
    if (urls.isEmpty) return null;

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

    return AppearanceCardData(
      photoUrls: urls.take(maxPhotos).toList(),
      photoLabels: labels.take(maxPhotos).toList(),
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
