/// A shareable snapshot of one report, as returned by `POST /share`
/// (`functions/bootstrap/share.py`).
class ReportShare {
  const ReportShare({
    required this.token,
    required this.url,
    required this.cardUrl,
    required this.title,
    required this.summary,
  });

  factory ReportShare.fromMap(Map<String, dynamic> m) => ReportShare(
        token: m['token'] as String? ?? '',
        url: m['url'] as String? ?? '',
        cardUrl: m['card_url'] as String? ?? '',
        title: m['title'] as String? ?? '',
        summary: m['summary'] as String? ?? '',
      );

  final String token;

  /// The public `https://…/s/<token>` page.
  final String url;

  /// `…/s/<token>/card.png` — append `?format=story` for the 1080x1920 card.
  final String cardUrl;
  final String title;
  final String summary;

  String get storyCardUrl => '$cardUrl?format=story';

  /// The one-line text that travels with the link everywhere it's shared.
  String get message =>
      summary.isEmpty ? '$title\n$url' : '$title — $summary\n$url';
}
