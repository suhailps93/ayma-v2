/// The context payload for one scoped "Ask Ayma" turn — what today's
/// tap-to-correct affordances (Story, deep-dive/web-research, Appearance)
/// hand to [ChatScreen] (via its `askAymaContext` constructor field) so the
/// conversation opens already scoped to whatever passage/finding/fact the
/// user tapped. Both [ChatScreen] (the one shared chat core) and
/// `ask_ayma_overlay.dart`'s `showAskAymaOverlay` (its public, unchanged
/// entry point) depend on this file.
library;

/// Which surface an [AskAymaContext] scopes a turn to — decides which
/// backend context fields ride along on `/chat`/`/chat/stream` (§ the
/// `story_*` fields for [story], `deep_dive_*` for the deep-dive report
/// origins, `appearance_finding_id` for the appearance origins) and which
/// quick-suggestion chips the modal offers (see [quickSuggestionsFor]).
enum AskAymaOrigin {
  story,
  deepDiveFact,
  deepDiveSummary,
  deepDiveSocial,
  deepDivePhoto,
  appearanceAttribute,
  appearanceFace,
  appearanceBody,
}

/// What one Ask Ayma turn is scoped to. For [AskAymaOrigin.story], carries
/// exactly what `skills/story_edit.py`'s tools need: `pageId`/`selectedText`
/// map to `story_page_id`/`story_passage`; `timelineEntryId` maps to the
/// newer `story_timeline_entry_id` field, which scopes
/// `edit_career_timeline_entry` / `delete_career_timeline_entry` instead. For
/// every other origin, `deepDiveReportId`/`deepDiveTarget` or
/// `appearanceFindingId` map to the matching backend fields that let the
/// conversational agent invoke `correct_deep_dive_item` /
/// `remove_deep_dive_item` / `correct_appearance_item` /
/// `clear_appearance_item` instead.
///
/// Forward-compat for the generic Living Report system (`report_hub.py` /
/// `report_blocks.py` server-side): [reportType]/[reportId]/[blockIds]/
/// [scope] let a future caller identify one or more report blocks the way
/// `POST /report/{report_type}/{report_id}/correct` (`report_hub.correct`)
/// expects, without adding another one-off `xyzFindingId`-shaped field here
/// every time a new report type shows up. They're unused by today's
/// `/chat`-routed origins above (which keep their own dedicated fields for
/// backend-compatibility reasons — the conversational agent's tools take
/// those specific names, not a generic block id) — see [reportCorrectBody]
/// for how a caller building on the generic endpoint instead would use them.
class AskAymaContext {
  const AskAymaContext({
    this.origin = AskAymaOrigin.story,
    this.pageId = '',
    this.selectedText = '',
    this.sectionTitle = '',
    this.timelineEntryId = '',
    this.timelineEntryLabel = '',
    this.isPrivate = false,
    this.deepDiveReportId = '',
    this.deepDiveTarget = '',
    this.appearanceFindingId = '',
    this.quoteTitle = '',
    this.quoteText = '',
    this.reportType = '',
    this.reportId = '',
    this.blockIds = const [],
    this.scope = 'block',
  });

  final AskAymaOrigin origin;
  final String pageId;
  final String selectedText;
  final String sectionTitle;
  final String timelineEntryId;
  final String timelineEntryLabel;

  /// Whether the tapped passage is currently private — decides which single
  /// privacy toggle heads the quick-suggestion chips (see
  /// [quickSuggestionsFor]). Meaningless (and ignored) outside
  /// [AskAymaOrigin.story], and for a timeline entry within it.
  final bool isPrivate;

  final String deepDiveReportId;
  final String deepDiveTarget;
  final String appearanceFindingId;

  /// The generic "quoted context" block the modal shows at the top — every
  /// origin sets these two instead of the modal branching on origin-specific
  /// fields for display purposes. Story still derives these from
  /// [sectionTitle]/[selectedText]/[timelineEntryLabel] at the call site.
  final String quoteTitle;
  final String quoteText;

  /// Which `report_hub.REPORT_TYPES` entry this turn is about (e.g.
  /// `'appearance'`, `'deep_dive'`, `'story_private'`), the report's own id,
  /// and the block(s)/scope within it — the shape `POST
  /// /report/{report_type}/{report_id}/correct` takes. See [reportCorrectBody].
  final String reportType;
  final String reportId;
  final List<String> blockIds;

  /// `'block'` | `'section'` | `'report'` — matches `ReportCorrectRequest`
  /// server-side (`main.py`); default `'block'`.
  final String scope;

  bool get isTimelineEntry => timelineEntryId.isNotEmpty;

  /// The request body `POST /report/{report_type}/{report_id}/correct`
  /// expects (`report_hub.correct`, `{block_ids, scope, message}`) — a pure,
  /// tested mapping from this context's [blockIds]/[scope] plus a caller-
  /// supplied [message], so a future caller (e.g. the generic Living Report
  /// renderer wiring a quick-suggestion chip straight to that REST endpoint,
  /// bypassing a full `/chat` turn) has one canonical place to build it
  /// instead of hand-rolling the map. Meaningful only when [blockIds] is
  /// non-empty — today's story/deep-dive/appearance origins above don't set
  /// it and keep going through `/chat` via their own dedicated fields.
  Map<String, Object> reportCorrectBody(String message) => {
    'block_ids': blockIds,
    'scope': scope,
    'message': message,
  };
}

/// The quick-suggestion chips, in order, for [ctx]'s origin. For
/// [AskAymaOrigin.story] the privacy toggle and delete always lead — ahead of
/// the content-editing suggestions — regardless of which way the toggle
/// currently points: `ctx.isPrivate` only picks its label ("Make public" vs
/// "Make private"), never its position.
List<String> quickSuggestionsFor(AskAymaContext ctx) => switch (ctx.origin) {
  AskAymaOrigin.story => [
    ctx.isPrivate ? 'Make public' : 'Make private',
    'Delete',
    'Make this more concise',
    'Add more details',
    'Rewrite in my tone',
  ],
  AskAymaOrigin.deepDiveFact => ['Delete', "That's not accurate"],
  AskAymaOrigin.deepDiveSummary => ["That's not accurate"],
  AskAymaOrigin.deepDiveSocial => ["That's not my link", 'Delete'],
  AskAymaOrigin.deepDivePhoto => ["That's not my photo", 'Delete'],
  AskAymaOrigin.appearanceAttribute => ["That's not correct", 'Delete'],
  AskAymaOrigin.appearanceFace => ["That's not correct"],
  AskAymaOrigin.appearanceBody => ["That's not correct"],
};
