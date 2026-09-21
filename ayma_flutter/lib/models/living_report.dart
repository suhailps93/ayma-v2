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
  /// `fact`.
  String get tag => _m['tag'] as String? ?? '';
  String get confidence => _m['confidence'] as String? ?? '';
  /// `attribute`.
  String get label => _m['label'] as String? ?? '';
  Object? get value => _m['value'];
  String get source => _m['source'] as String? ?? '';
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
        sections: ((m['sections'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ReportSection.fromMap(e.cast<String, dynamic>()))
            .toList(),
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
