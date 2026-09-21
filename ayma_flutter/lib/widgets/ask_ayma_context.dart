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

  /// A generic Living Report tap-to-correct turn (§ generic reports) — the
  /// owner tapped a block/section/report-header on the shared
  /// `LivingReportView` renderer. Unlike every origin above (which rides its
  /// own dedicated `/chat` fields), this one is sent to `/chat` at all —
  /// [ChatScreen] routes it straight to `POST
  /// /report/{report_type}/{report_id}/correct` via [reportCorrectBody]
  /// instead, since that's the ONE thing `report_hub.correct` needs (see
  /// that endpoint's own docstring: quick actions and free-text corrections
  /// both travel through it). [quickSuggestionsFor] picks candidate-only
  /// ("This is me"/"Not me") or the normal make-public/make-private/delete
  /// set based on [isCandidate].
  report,

  /// The read-only counterpart to [report]: a non-owner tapped a block on
  /// someone else's report (a deep-dive or public Story). Genuine free-text
  /// Q&A still works (plain `/chat`, using [quoteTitle]/[quoteText] for
  /// context) but there's nothing to correct — no quick-action chips, and
  /// [reportType]/[blockIds] are left unset so nothing here can accidentally
  /// resolve to a mutation attempt (§ founder: never present UI that implies
  /// a non-owner can edit someone else's report).
  reportView,
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
    this.isCandidate = false,
  });

  final AskAymaOrigin origin;
  final String pageId;
  final String selectedText;
  final String sectionTitle;
  final String timelineEntryId;
  final String timelineEntryLabel;

  /// Whether the tapped passage/block is currently private — decides which
  /// single privacy-toggle chip heads the quick-suggestion chips (`true` ->
  /// "Make public"; `false` -> "Make private"; see [quickSuggestionsFor]).
  /// Meaningless (and ignored) outside [AskAymaOrigin.story] and
  /// [AskAymaOrigin.report] (and, within [AskAymaOrigin.story], for a
  /// timeline entry). For [AskAymaOrigin.report] most block types carry no
  /// visibility field of their own, so `LivingReportView` falls back to a
  /// REPORT-TYPE-level guess: `story_public` (everything narrative shown
  /// there is already public) -> `false` (offers "Make private"); every
  /// other type -> `true` (offers "Make public"). The one exception is a
  /// `story_public` attribute block (a physical-attribute field, private by
  /// default — see `ReportBlock.public`): that carries its OWN real
  /// visibility on the owner's read, and `LivingReportView._isPrivateFor`
  /// uses that actual value instead of the report-wide guess whenever every
  /// targeted block is one of those.
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

  /// [AskAymaOrigin.report] only: whether every block in [blockIds] is a
  /// pending reverse-image-search candidate (`candidate:<id>` — deep-dive's
  /// "Photos to confirm" section). Picks the "This is me"/"Not me" chip pair
  /// instead of the normal make-public/make-private/delete set — see
  /// [quickSuggestionsFor]. Ignored for every other origin.
  final bool isCandidate;

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
  // The ONLY default quick-actions on a generic Living Report block (§
  // founder spec): a pending photo candidate gets "This is me"/"Not me"
  // (report_hub.QUICK_CONFIRM_ME/QUICK_NOT_ME — the sole decision to make on
  // one, no free-text correction path exists for it server-side); every
  // other editable block gets the make-public/make-private toggle (labelled
  // from ctx.isPrivate) plus "Delete" — nothing else canned, anything else
  // typed is free conversation.
  AskAymaOrigin.report => ctx.isCandidate
      ? ['This is me', 'Not me']
      : [ctx.isPrivate ? 'Make public' : 'Make private', 'Delete'],
  // Read-only Q&A about someone else's report: no chips at all — see
  // [AskAymaOrigin.reportView]'s doc.
  AskAymaOrigin.reportView => const [],
};
