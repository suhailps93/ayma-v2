/// A public page-share link, as returned by `POST /share-link`
/// (`functions/bootstrap/page_share.py`): an unguessable token behind
/// `https://justabot.info/p/<token>`, where the target's frozen PUBLIC
/// snapshot is the landing page.
class LinkShare {
  const LinkShare({
    required this.token,
    required this.url,
    required this.title,
    required this.summary,
  });

  factory LinkShare.fromMap(Map<String, dynamic> m) => LinkShare(
        token: m['token'] as String? ?? '',
        url: m['url'] as String? ?? '',
        title: m['title'] as String? ?? '',
        summary: m['summary'] as String? ?? '',
      );

  final String token;
  final String url;
  final String title;
  final String summary;

  /// The one-line text that travels with the link everywhere it's shared.
  String get message =>
      summary.isEmpty ? '$title\n$url' : '$title — $summary\n$url';
}

/// The target identity behind a `/p/<token>` link, as returned by
/// `GET /p/{token}/data` — what the app's deep-link route resolves before
/// opening the target natively.
class PageShareTarget {
  const PageShareTarget({
    required this.kind,
    required this.targetId,
    required this.title,
    required this.summary,
  });

  factory PageShareTarget.fromMap(Map<String, dynamic> m) => PageShareTarget(
        kind: m['kind'] as String? ?? '',
        targetId: m['target_id'] as String? ?? '',
        title: m['title'] as String? ?? '',
        summary: m['summary'] as String? ?? '',
      );

  final String kind;
  final String targetId;
  final String title;
  final String summary;

  /// The in-app route that opens this target, or empty when this build
  /// doesn't know the kind (a newer kind shared by a newer app version).
  String get route => switch (kind) {
        'profile' => '/profile/user/$targetId',
        _ => '',
      };
}
