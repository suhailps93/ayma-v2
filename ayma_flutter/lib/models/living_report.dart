/// Dart models for the generic, block-shaped "Living Report" the backend
/// exposes via `GET /report/{report_type}/{report_id}` and
/// `POST /report/{report_type}/{report_id}/correct` (see
/// `functions/bootstrap/report_blocks.py` / `report_adapters.py` /
/// `report_hub.py` — this file is a pure, read-only mirror of that shape,
/// nothing here changes any producer's storage).
///
/// [ReportBlock] is deliberately one class for all eight block types
/// (`text`/`fact`/`attribute`/`photo`/`photo_grid`/`link`/`stat`/
/// `section_head`) rather than a sealed hierarchy — a renderer switches on
/// [ReportBlock.type] and reads whichever of the type-specific getters
/// apply; there's no subclass tree to keep in sync with the server's own
/// small, fixed set of shapes.
library;

// --- block types (mirrors report_blocks.py's ALL_TYPES) --------------------

const kBlockText = 'text';
const kBlockFact = 'fact';
const kBlockAttribute = 'attribute';
const kBlockPhoto = 'photo';
const kBlockPhotoGrid = 'photo_grid';
const kBlockLink = 'link';
const kBlockStat = 'stat';
const kBlockSectionHead = 'section_head';

class ReportBlock {
  const ReportBlock(this._m);

  factory ReportBlock.fromMap(Map<String, dynamic> m) => ReportBlock(m);

  final Map<String, dynamic> _m;

  String get blockId => _m['block_id'] as String? ?? '';
  String get type => _m['type'] as String? ?? '';
  bool get editable => _m['editable'] as bool? ?? false;

  /// `text` / `fact` / `section_head`.
  String get text => _m['text'] as String? ?? '';
  /// `text` only — Story's inline `{{private}}`/`{{ai_only}}` span kind
  /// this sentence was cut from (`"private"` / `"ai_only"`), or `null` for
  /// ordinary public text (see `report_blocks.text_block`'s `tone`).
  /// Styling-only: never a correction target of its own.
  String? get tone => _m['tone'] as String?;
  /// `fact`.
  String get tag => _m['tag'] as String? ?? '';
  String get confidence => _m['confidence'] as String? ?? '';
  /// `attribute`.
  String get label => _m['label'] as String? ?? '';
  Object? get value => _m['value'];
  String get source => _m['source'] as String? ?? '';
  /// `attribute`, owner's own `story_public` read only (§ founder:
  /// attributes are private by default) — whether THIS field is currently
  /// public on the Story-public Living Report. `null` everywhere else:
  /// Appearance's own Attributes section has no visibility concept at all,
  /// and a non-owner's `story_public` read only ever gets the pre-filtered
  /// public subset in the first place (see `report_blocks.attribute_block`/
  /// `report_adapters.story_public_blocks`).
  bool? get public => _m['public'] as bool?;
  /// `photo` (and the display url for `link`).
  String get url => _m['url'] as String? ?? '';
  String get caption => _m['caption'] as String? ?? '';
  bool? get verified => _m['verified'] as bool?;
  /// `"pending"` for a reverse-image-search candidate awaiting confirm/reject
  /// (see [isCandidate]); absent otherwise.
  String? get status => _m['status'] as String?;
  bool get isPending => status == 'pending';
  /// A pending reverse-image-search candidate — `deep_dive`'s "Photos to
  /// confirm" section (`candidate:<id>` block ids), the ONE block kind whose
  /// quick actions are "This is me" / "Not me" instead of the normal
  /// make-public/make-private/delete set (see `report_hub.py`'s
  /// `QUICK_CONFIRM_ME`/`QUICK_NOT_ME`).
  bool get isCandidate => blockId.startsWith('candidate:');
  /// `photo_grid`.
  List<Map<String, dynamic>> get photos =>
      ((_m['photos'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
  /// `link`.
  String get linkLabel => _m['label'] as String? ?? '';
  /// `stat`.
  String get basis => _m['basis'] as String? ?? '';
}

class ReportSection {
  const ReportSection({required this.heading, required this.blocks});

  factory ReportSection.fromMap(Map<String, dynamic> m) => ReportSection(
        heading: m['heading'] as String? ?? '',
        blocks: ((m['blocks'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReportBlock.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );

  final String heading;
  final List<ReportBlock> blocks;

  List<String> get blockIds => [for (final b in blocks) b.blockId];
}

const _kLinksHeading = 'Links';
const _kSocialHeading = 'Social profiles';
const _trackingParams = {
  'fbclid', 'gclid', 'dclid', 'msclkid', 'igshid', 'igsh', 'mc_cid',
  'mc_eid', 'ref', 'ref_src', 'ref_url', 'si', 'feature', 'trk', 'trkinfo',
  'cmpid', '_hsenc', '_hsmi', 'spm',
};
const _socialHosts = {
  'instagram.com': 'instagram',
  'twitter.com': 'x',
  'x.com': 'x',
  'linkedin.com': 'linkedin',
  'facebook.com': 'facebook',
  'fb.com': 'facebook',
  'tiktok.com': 'tiktok',
  'github.com': 'github',
  'youtube.com': 'youtube',
};

String _hostOf(Uri u) =>
    u.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|mobile)\.'), '');

/// Comparison key for a URL: no scheme, `www`, fragment, tracking params or
/// trailing slash; host lower-cased. Mirrors `deep_dive_links.url_key`.
String normalizedUrlKey(String url) {
  var raw = url.trim();
  if (raw.isEmpty) return '';
  if (!raw.contains('//')) raw = 'https://$raw';
  final u = Uri.tryParse(raw);
  if (u == null || u.host.isEmpty) return '';
  final pairs = [
    for (final e in u.queryParametersAll.entries)
      if (!_trackingParams.contains(e.key.toLowerCase()) &&
          !e.key.toLowerCase().startsWith('utm_'))
        for (final v in e.value) '${e.key}=$v',
  ]..sort();
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return _hostOf(u) + path + (pairs.isEmpty ? '' : '?${pairs.join('&')}');
}

/// Platform key when [url] is a person's profile page on a social network
/// (`/user`, `/in/handle`, `/@handle`, ...), else `null` - a repo, video or
/// post on the same site is an ordinary link.
String? socialProfilePlatform(String url) {
  var raw = url.trim();
  if (!raw.contains('//')) raw = 'https://$raw';
  final u = Uri.tryParse(raw);
  if (u == null) return null;
  final platform = _socialHosts[_hostOf(u)];
  if (platform == null) return null;
  final segs = [for (final s in u.pathSegments) if (s.isNotEmpty) s];
  switch (platform) {
    case 'github':
      return segs.length == 1 ? platform : null;
    case 'linkedin':
      return segs.length >= 2 && (segs[0] == 'in' || segs[0] == 'pub')
          ? platform
          : null;
    case 'youtube':
      if (segs.isEmpty) return null;
      if (segs[0].startsWith('@')) return platform;
      return segs.length >= 2 &&
              (segs[0] == 'c' || segs[0] == 'user' || segs[0] == 'channel')
          ? platform
          : null;
    case 'tiktok':
      return segs.isNotEmpty && segs[0].startsWith('@') ? platform : null;
    case 'facebook':
      if (segs.length == 1 && segs[0] == 'profile.php') {
        return u.queryParameters['id'] != null ? platform : null;
      }
      return segs.length == 1 ? platform : null;
    default:
      return segs.length == 1 ? platform : null;
  }
}

/// Defensive de-dupe for reports stored before the backend cleaned them:
/// "Social profiles" keeps one row per platform (and per URL), "Links" keeps
/// only non-profile pages, one per normalised URL, and Social profiles is
/// listed first. Empty sections are dropped. Other sections are untouched.
List<ReportSection> dedupeLinkSections(List<ReportSection> sections) {
  final socialIdx = sections.indexWhere((s) => s.heading == _kSocialHeading);
  final linksIdx = sections.indexWhere((s) => s.heading == _kLinksHeading);
  if (socialIdx < 0 && linksIdx < 0) return sections;

  final platforms = <String>{};
  final keys = <String>{};
  final socialBlocks = <ReportBlock>[];
  if (socialIdx >= 0) {
    for (final b in sections[socialIdx].blocks) {
      final platform = b.tag.isNotEmpty
          ? b.tag.toLowerCase()
          : (socialProfilePlatform(b.url) ?? b.url);
      final key = normalizedUrlKey(b.url);
      if (key.isEmpty || platforms.contains(platform) || keys.contains(key)) {
        continue;
      }
      platforms.add(platform);
      keys.add(key);
      socialBlocks.add(b);
    }
  }
  final linkBlocks = <ReportBlock>[];
  if (linksIdx >= 0) {
    for (final b in sections[linksIdx].blocks) {
      final key = normalizedUrlKey(b.url);
      if (key.isEmpty || keys.contains(key)) continue;
      if (b.type == kBlockLink && socialProfilePlatform(b.url) != null) {
        continue;
      }
      keys.add(key);
      linkBlocks.add(b);
    }
  }

  final out = <ReportSection>[];
  for (var i = 0; i < sections.length; i++) {
    if (i == socialIdx) continue;
    if (i == linksIdx) {
      if (socialBlocks.isNotEmpty) {
        out.add(ReportSection(heading: _kSocialHeading, blocks: socialBlocks));
      }
      if (linkBlocks.isNotEmpty) {
        out.add(ReportSection(heading: _kLinksHeading, blocks: linkBlocks));
      }
    } else {
      out.add(sections[i]);
    }
  }
  if (linksIdx < 0 && socialBlocks.isNotEmpty) {
    out.insert(
      socialIdx.clamp(0, out.length),
      ReportSection(heading: _kSocialHeading, blocks: socialBlocks),
    );
  }
  return out;
}

class ReportMeta {
  const ReportMeta({
    required this.ownerUid,
    required this.viewerCanEdit,
    this.createdAt,
    this.updatedAt,
  });

  factory ReportMeta.fromMap(Map<String, dynamic> m) => ReportMeta(
        ownerUid: m['owner_uid'] as String? ?? '',
        viewerCanEdit: m['viewer_can_edit'] as bool? ?? false,
        createdAt: m['created_at'] as String?,
        updatedAt: m['updated_at'] as String?,
      );

  final String ownerUid;
  final bool viewerCanEdit;
  final String? createdAt;
  final String? updatedAt;
}

/// `GET /report/{report_type}/{report_id}` response — `{title, sections,
/// meta}` (`report_hub.get_report`).
class LivingReport {
  const LivingReport({
    required this.title,
    required this.sections,
    required this.meta,
  });

  factory LivingReport.fromMap(Map<String, dynamic> m) => LivingReport(
        title: m['title'] as String? ?? '',
        sections: dedupeLinkSections(((m['sections'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReportSection.fromMap(e.cast<String, dynamic>()))
            .toList()),
        meta: ReportMeta.fromMap(
          (m['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );

  final String title;
  final List<ReportSection> sections;
  final ReportMeta meta;

  /// Every block id in the report, section order preserved — what a
  /// report-header tap sends as `block_ids` with `scope: "report"`.
  List<String> get allBlockIds => [
        for (final s in sections) ...s.blockIds,
      ];

  /// The block with this id, or `null` when it isn't on the report at all.
  ReportBlock? blockById(String id) {
    for (final s in sections) {
      for (final b in s.blocks) {
        if (b.blockId == id) return b;
      }
    }
    return null;
  }
}

/// One block's outcome inside a `POST /report/{type}/{id}/correct` response.
class ReportCorrectItem {
  const ReportCorrectItem({
    required this.blockId,
    required this.ok,
    required this.reply,
    this.usageCapped = false,
  });

  factory ReportCorrectItem.fromMap(Map<String, dynamic> m) =>
      ReportCorrectItem(
        blockId: m['block_id'] as String? ?? '',
        ok: m['ok'] as bool? ?? false,
        reply: m['reply'] as String? ?? '',
        usageCapped: m['usage_capped'] as bool? ?? false,
      );

  final String blockId;
  final bool ok;
  final String reply;
  final bool usageCapped;
}

/// `POST /report/{type}/{id}/correct` response — `{ok, results}`
/// (`report_hub.correct`).
class ReportCorrectResult {
  const ReportCorrectResult({required this.ok, required this.results});

  factory ReportCorrectResult.fromMap(Map<String, dynamic> m) =>
      ReportCorrectResult(
        ok: m['ok'] as bool? ?? false,
        results: ((m['results'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReportCorrectItem.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );

  final bool ok;
  final List<ReportCorrectItem> results;

  bool get usageCapped => results.any((r) => r.usageCapped);

  /// A single chat-bubble-ready reply string: every distinct non-empty
  /// per-block reply, joined — never empty (falls back to a generic
  /// ok/failed line) so the chat transcript always has something to show
  /// even when the server resolved several blocks at once (a section/report
  /// scope bundle).
  String get combinedReply {
    final distinct = <String>{
      for (final r in results)
        if (r.reply.trim().isNotEmpty) r.reply.trim(),
    };
    if (distinct.isEmpty) return ok ? 'Done.' : "Couldn't do that.";
    return distinct.join('\n\n');
  }
}
