import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/living_report.dart';
import '../services/api_client.dart';
import '../theme.dart';
import 'ask_ayma_overlay.dart';
import 'ayma_orb.dart';

/// The ONE shared, block-based renderer for every "Living Report" —
/// Appearance, deep-dive/web-search, and Story in each of its three view
/// modes (`story_private` / `story_public` / `story_ai_notes`). Fetches
/// `GET /report/{reportType}/{reportId}` and renders its `{title, sections}`
/// with three tap tiers plus ad-hoc multi-select, all routed through the
/// SAME mechanism: opening the shared Ask-Ayma chat modal
/// ([showAskAymaOverlay]) scoped via [AskAymaContext.reportType]/
/// [AskAymaContext.blockIds]/[AskAymaContext.scope], which
/// [AskAymaOrigin.report] turns into `POST
/// /report/{reportType}/{reportId}/correct` instead of a normal `/chat` turn
/// (see `ChatScreen._send`).
///
/// [reportId] means something different per [reportType] — mirrors
/// `report_hub.resolve_owner`: the caller's own uid for every type except
/// `"deep_dive"` (a real, previously-run deep-dive report id); every other
/// type has exactly one report per user, so its "id" IS the uid.
///
/// --- Typography contract (§ founder: one hierarchy, not one per screen) ---
/// Exactly three roles, applied nowhere else in this file:
///  * [_titleStyle]   — the report's own title. Serif display, size 24.
///  * [_headingStyle] — a section heading. Mono, all-caps letter-spaced
///    eyebrow, size 11 — matches Story's existing numbered-section
///    convention, now the ONE section-heading style everywhere.
///  * [_bodyStyle]    — flowing sentence/prose text (`text` blocks). Serif,
///    size 17, line-height 1.6 — Story's existing prose treatment, now
///    shared by every report type's narrative text instead of each screen
///    picking its own.
/// Structured line-item blocks (fact/attribute/photo/link/stat) are UI
/// chrome around that prose, not prose themselves — they use the app's
/// ordinary sans body/label styles, same as Appearance/deep-dive already did,
/// not [_bodyStyle].
class LivingReportView extends StatefulWidget {
  const LivingReportView({
    super.key,
    required this.reportType,
    required this.reportId,
    this.apiClient,
    this.emptyMessage = 'Nothing here yet.',
    this.onLoaded,
    this.shrinkWrap = false,
    this.showTitle = true,
  });

  final String reportType;
  final String reportId;
  final ApiClient? apiClient;

  /// Shown in place of the section list when the report has no sections at
  /// all.
  final String emptyMessage;

  /// When true, the internal section list sizes to its content and never
  /// scrolls on its own (`shrinkWrap: true` + `NeverScrollableScrollPhysics`)
  /// — for a caller (Story's editor screen — § generic reports) that embeds
  /// this widget as one item inside ITS OWN outer scrollable alongside other,
  /// not-yet-block-modeled content (cover stats, the photo gallery, the
  /// career timeline, the merged Appearance card) rather than giving this
  /// report the whole screen the way Appearance/deep-dive/My-public-profile
  /// do. Default `false` (an independently scrolling full-screen list) is
  /// unchanged for every other caller.
  final bool shrinkWrap;

  /// When false, the report's own title (report-tier tap target) is
  /// omitted — for the same Story embedding [shrinkWrap] serves: Story's own
  /// screen already shows a large title of its own ("Your Story" / "Public
  /// view" / "Ayma's Notes") in its cover, so this report's title would
  /// otherwise repeat it immediately above the very same narrative content.
  /// The report-tier tap itself is still reachable there — a whole-report
  /// correction just isn't a headline UI affordance in that context.
  final bool showTitle;

  /// Fires every time the report (re)loads successfully — lets a host
  /// screen react to fresh data (e.g. an AppBar action that needs the
  /// report's own name) without this widget knowing about that screen's
  /// concerns.
  final void Function(LivingReport report)? onLoaded;

  @override
  State<LivingReportView> createState() => LivingReportViewState();
}

class LivingReportViewState extends State<LivingReportView> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();

  /// The last successfully loaded report, kept mounted across a reload
  /// (§ `reload` doc: stale-while-revalidate, not swap-for-a-spinner) —
  /// `null` only before the very first load resolves.
  LivingReport? _report;
  bool _loadFailed = false;

  /// Ad-hoc multi-select (§ founder point 4): every block id the user has
  /// checked, across any section, any combination. Non-empty <=> selection
  /// mode is active.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.getReport(widget.reportType, widget.reportId);
      if (!mounted) return;
      setState(() {
        _report = r;
        _loadFailed = false;
      });
      widget.onLoaded?.call(r);
    } catch (_) {
      if (!mounted) return;
      // A background reload failing leaves the still-good `_report` on
      // screen rather than blanking it out; only the very first load
      // surfaces the retry screen (§ build: `_ErrorMessage` only shows when
      // `_report` is still null).
      setState(() => _loadFailed = true);
    }
  }

  /// Re-fetches the whole report — called once the Ask Ayma overlay closes
  /// on a turn that actually changed something. Deliberately does NOT tear
  /// down and rebuild the section list while the fetch is in flight (no
  /// `FutureBuilder`-style loading state once there's already a `_report` on
  /// screen — § bug: that swap used to unmount the `ListView` and reset its
  /// scroll offset to the top on every single dismiss, even a plain no-op
  /// one). The old content stays exactly where the user left it, in place,
  /// until the fresh data lands and swaps in.
  void reload() => _load();

  bool get _selecting => _selected.isNotEmpty;

  void _enterSelection(String blockId) =>
      setState(() => _selected..clear()..add(blockId));

  void _toggle(String blockId) => setState(() {
        if (!_selected.remove(blockId)) _selected.add(blockId);
      });

  void _cancelSelection() => setState(_selected.clear);

  /// Opens the shared chat modal scoped to [blockIds]/[scope]. When the
  /// current viewer can't edit this report, the correction fields are left
  /// unset (§ founder point 9: never wire a mutation attempt for a
  /// non-owner) — the modal still opens for genuine read-only Q&A, using
  /// [quoteTitle]/[quoteText] for context, via the normal `/chat` path.
  Future<void> _open({
    required LivingReport report,
    required List<String> blockIds,
    required String scope,
    required String quoteTitle,
    required String quoteText,
  }) async {
    final canEdit = report.meta.viewerCanEdit;
    final candidate = canEdit &&
        blockIds.isNotEmpty &&
        blockIds.every((id) => id.startsWith('candidate:'));
    setState(_selected.clear);
    // `onExchange` already re-fetches after every reply Ayma gives while the
    // modal is open (see `showAskAymaOverlay`'s doc) — that's the ONLY
    // reload this method triggers. A plain dismiss with no message sent (tap
    // outside, drag down, the X) fires no exchange, so nothing re-fetches
    // (§ bug: this used to unconditionally reload once more right here,
    // after every dismiss whether or not anything changed, which reset the
    // report's scroll position back to the top even on a genuine no-op).
    await showAskAymaOverlay(
      context,
      api: _api,
      ctx: AskAymaContext(
        origin: canEdit ? AskAymaOrigin.report : AskAymaOrigin.reportView,
        reportType: canEdit ? widget.reportType : '',
        reportId: canEdit ? widget.reportId : '',
        blockIds: canEdit ? blockIds : const [],
        scope: scope,
        isCandidate: candidate,
        // Best available signal for current public/private state — the
        // generic block model carries no visibility field (see
        // `AskAymaContext.isPrivate`'s doc: true -> offers "Make public",
        // false -> offers "Make private"). `story_public` shows only
        // already-public content, so it's the one type that should offer
        // "Make private" (isPrivate: false); every other type defaults to
        // the "currently private" assumption (isPrivate: true), offering
        // "Make public".
        isPrivate: widget.reportType != 'story_public',
        quoteTitle: quoteTitle,
        quoteText: quoteText,
      ),
      onExchange: reload,
    );
  }

  void _openReport(LivingReport report) => _open(
        report: report,
        blockIds: report.allBlockIds,
        scope: 'report',
        quoteTitle: report.title,
        quoteText: _reportSummary(report),
      );

  void _openSection(LivingReport report, ReportSection section) => _open(
        report: report,
        blockIds: section.blockIds,
        scope: 'section',
        quoteTitle: section.heading,
        quoteText: _sectionSummary(section),
      );

  /// A short "what am I about to edit" summary for a whole-section tap — the
  /// quoted-context card (`_AskAymaHeader` in `chat_screen.dart`) only shows
  /// when `quoteText` is non-empty, and a single block already gets a real
  /// quote via [_quoteTextFor]. Section/report scope has no one block's text
  /// to quote, so this stands in: how many items are in scope, plus a short
  /// preview of their content when any block actually has quotable text
  /// (§ bug: this used to always pass `''`, so the card silently never
  /// appeared for a section/report tap — not "no context", just never wired).
  String _sectionSummary(ReportSection section) =>
      _scopeSummary(section.blockIds.length, section.blocks);

  /// Same idea as [_sectionSummary], for a whole-report tap.
  String _reportSummary(LivingReport report) {
    final n = report.sections.length;
    final sectionLabel = n == 1 ? '1 section' : '$n sections';
    final blocks = [for (final s in report.sections) ...s.blocks];
    return '$sectionLabel · ${_scopeSummary(report.allBlockIds.length, blocks)}';
  }

  String _scopeSummary(int itemCount, List<ReportBlock> blocks) {
    final itemLabel = itemCount == 1 ? '1 item' : '$itemCount items';
    final preview = blocks
        .map(_quoteTextFor)
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .take(3)
        .join(' · ');
    return preview.isEmpty ? itemLabel : '$itemLabel — $preview';
  }

  void _openBlock(LivingReport report, ReportBlock block) => _open(
        report: report,
        blockIds: [block.blockId],
        scope: 'block',
        quoteTitle: _quoteTitleFor(block),
        quoteText: _quoteTextFor(block),
      );

  void _openSelection(LivingReport report) => _open(
        report: report,
        blockIds: _selected.toList(),
        scope: 'block',
        quoteTitle: '${_selected.length} selected',
        quoteText: '',
      );

  String _quoteTitleFor(ReportBlock b) => switch (b.type) {
        kBlockAttribute => b.label,
        kBlockFact => b.tag.isNotEmpty ? b.tag : 'Claim',
        kBlockStat => b.label,
        kBlockLink => b.linkLabel.isNotEmpty ? b.linkLabel : 'Link',
        kBlockPhoto => b.isCandidate ? 'Photo to confirm' : 'Photo',
        _ => 'This',
      };

  String _quoteTextFor(ReportBlock b) => switch (b.type) {
        kBlockText || kBlockFact || kBlockSectionHead => b.text,
        kBlockAttribute => '${b.value}',
        kBlockStat => '${b.value}${b.basis.isEmpty ? '' : ' · ${b.basis}'}',
        kBlockPhoto => b.caption.isNotEmpty ? b.caption : b.url,
        kBlockLink => b.url,
        _ => '',
      };

  /// Whether [block] can be tapped/long-pressed at all: an `editable: false`
  /// block (§ `report_blocks.py`: "a client-side hint so a non-correctable
  /// block ... doesn't invite a tap that can only ever fail") is inert for
  /// an editing owner; a non-owner may still tap it for read-only Q&A.
  bool _tappable(ReportBlock b, bool canEdit) => !canEdit || b.editable;

  @override
  Widget build(BuildContext context) {
    final report = _report;
    if (report == null) {
      if (_loadFailed) return _ErrorMessage(onRetry: reload);
      return const Center(
        child: AymaOrb(size: 64, state: AymaOrbState.thinking),
      );
    }
    return _buildReport(context, report);
  }

  Widget _buildReport(BuildContext context, LivingReport report) {
    final ac = context.ac;
    final canEdit = report.meta.viewerCanEdit;
    final list = ListView(
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
        20, 16, 20, (_selecting && !widget.shrinkWrap) ? 96 : 40,
      ),
      children: [
            if (widget.showTitle) ...[
              GestureDetector(
                key: const ValueKey('livingReportTitle'),
                onTap: _selecting || report.allBlockIds.isEmpty
                    ? null
                    : () => _openReport(report),
                child: Text(report.title, style: _titleStyle(ac.fg)),
              ),
              const SizedBox(height: 24),
            ],
            if (report.sections.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  widget.emptyMessage,
                  style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
                ),
              ),
            for (final section in report.sections) ...[
              _SectionView(
                section: section,
                report: report,
                canEdit: canEdit,
                selected: _selected,
                selecting: _selecting,
                onHeadingTap: _selecting || section.blockIds.isEmpty
                    ? null
                    : () => _openSection(report, section),
                onBlockTap: (b) {
                  if (!_tappable(b, canEdit)) return;
                  if (_selecting) {
                    _toggle(b.blockId);
                  } else if (b.type != kBlockText) {
                    _openBlock(report, b);
                  }
                },
                onBlockLongPress: (b) {
                  if (!canEdit || !_tappable(b, canEdit)) return;
                  _enterSelection(b.blockId);
                },
              ),
              const SizedBox(height: 28),
            ],
      ],
    );

    final selectionBar = _SelectionBar(
      count: _selected.length,
      onCancel: _cancelSelection,
      onChat: () => _openSelection(report),
    );

    // Embedded (shrinkWrap) mode has no bounded viewport of its own to pin a
    // floating bar to (it sizes to its content, inside a HOST screen's own
    // outer scrollable) — the selection bar renders as a normal trailing
    // item instead of a `Positioned` overlay there; everywhere else
    // (Appearance/deep-dive/My-public-profile/Story's own full-bleed use)
    // it's still the floating bottom bar.
    if (widget.shrinkWrap) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          list,
          if (_selecting) selectionBar,
        ],
      );
    }
    return Stack(
      children: [
        list,
        if (_selecting)
          Positioned(left: 0, right: 0, bottom: 0, child: selectionBar),
      ],
    );
  }
}

// --- typography (§ contract — see class doc) --------------------------------

TextStyle _titleStyle(Color color) => AymaType.serif(size: 24, color: color);

TextStyle _headingStyle(Color color) =>
    AymaType.mono(size: 15, color: color).copyWith(letterSpacing: 1.8);

TextStyle _bodyStyle(Color color) =>
    AymaType.serif(size: 17, color: color).copyWith(height: 1.6);

// --- section / block rendering ----------------------------------------------

class _SectionView extends StatelessWidget {
  const _SectionView({
    required this.section,
    required this.report,
    required this.canEdit,
    required this.selected,
    required this.selecting,
    required this.onHeadingTap,
    required this.onBlockTap,
    required this.onBlockLongPress,
  });

  final ReportSection section;
  final LivingReport report;
  final bool canEdit;
  final Set<String> selected;
  final bool selecting;
  final VoidCallback? onHeadingTap;
  final void Function(ReportBlock) onBlockTap;
  final void Function(ReportBlock) onBlockLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // Consecutive `text` blocks render as one continuous flowing paragraph
    // (§ founder point 2) rather than one row per sentence; every other
    // block type gets its own row widget, in original order.
    final rows = <Widget>[];
    var run = <ReportBlock>[];
    void flush() {
      if (run.isEmpty) return;
      rows.add(_ProseFlow(
        blocks: run,
        selected: selected,
        selecting: selecting,
        onTap: onBlockTap,
        onLongPress: onBlockLongPress,
      ));
      run = [];
    }

    for (final b in section.blocks) {
      if (b.type == kBlockText) {
        run.add(b);
        continue;
      }
      flush();
      rows.add(_BlockRow(
        block: b,
        selected: selected.contains(b.blockId),
        selecting: selecting,
        onTap: () => onBlockTap(b),
        onLongPress: () => onBlockLongPress(b),
      ));
    }
    flush();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          key: ValueKey('livingReportSection:${section.heading}'),
          onTap: onHeadingTap,
          child: Text(section.heading.toUpperCase(), style: _headingStyle(ac.accent)),
        ),
        const SizedBox(height: 12),
        for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 10), child: r),
      ],
    );
  }
}

/// One or more consecutive `text` blocks flowed as continuous prose. Each
/// sentence is its own tap target via [WidgetSpan] (not a bare
/// [TextSpan.recognizer]) so it can show a real highlight background and a
/// real hit-test rect — a small inline [TextSpan] tap is exactly the
/// "fragile bare inline tap" § founder point 2 calls out. A plain short tap
/// does nothing outside selection mode (a sentence is too easy to mis-tap
/// for that to be a deliberate action); only a long-press — or, once
/// already selecting, a tap — resolves to anything.
class _ProseFlow extends StatelessWidget {
  const _ProseFlow({
    required this.blocks,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final List<ReportBlock> blocks;
  final Set<String> selected;
  final bool selecting;
  final void Function(ReportBlock) onTap;
  final void Function(ReportBlock) onLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final style = _bodyStyle(ac.fg);
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Sentence(
                block: blocks[i],
                style: style,
                isSelected: selected.contains(blocks[i].blockId),
                selecting: selecting,
                onTap: () => onTap(blocks[i]),
                onLongPress: () => onLongPress(blocks[i]),
              ),
            ),
            if (i != blocks.length - 1) TextSpan(text: ' ', style: style),
          ],
        ],
      ),
    );
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence({
    required this.block,
    required this.style,
    required this.isSelected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final ReportBlock block;
  final TextStyle style;
  final bool isSelected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return GestureDetector(
      key: ValueKey('livingReportBlock:${block.blockId}'),
      behavior: HitTestBehavior.opaque,
      onTap: selecting ? onTap : null,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? ac.accent.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(block.text, style: style),
      ),
    );
  }
}

/// A structured, single-line-item block (fact/attribute/photo/photo_grid/
/// link/stat/section_head) — a row, not prose. Short tap opens chat for just
/// this block outside selection mode; long-press enters selection mode.
class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.block,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final ReportBlock block;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final child = switch (block.type) {
      kBlockSectionHead => Text(block.text,
          style: AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
      kBlockFact => _FactRow(block: block),
      kBlockAttribute => _AttributeRow(block: block),
      kBlockStat => _StatRow(block: block),
      kBlockLink => _LinkRow(block: block),
      kBlockPhoto => _PhotoRow(block: block),
      kBlockPhotoGrid => _PhotoGridRow(block: block),
      _ => Text(block.text, style: AymaType.sans(size: 14, color: ac.fg)),
    };
    return GestureDetector(
      key: ValueKey('livingReportBlock:${block.blockId}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? ac.accent.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selecting) ...[
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: selected ? ac.accent : ac.fgMute,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final conf = block.confidence.isEmpty ? '' : ' · ${block.confidence}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('• ${block.text}',
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
        if (block.tag.isNotEmpty || conf.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 2),
            child: Text('${block.tag}$conf',
                style: AymaType.mono(size: 9, color: ac.fgMute)),
          ),
      ],
    );
  }
}

class _AttributeRow extends StatelessWidget {
  const _AttributeRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 128,
          child: Text(block.label, style: AymaType.sans(size: 13, color: ac.fgMute)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${block.value}',
              style: AymaType.sans(size: 14, color: ac.fg, height: 1.35)),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('${block.value}',
            style: AymaType.serif(size: 22, color: ac.fg)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            [block.label, block.basis].where((s) => s.isNotEmpty).join(' · '),
            style: AymaType.sans(size: 12.5, color: ac.fgMute),
          ),
        ),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      children: [
        Expanded(
          child: Text(
            block.linkLabel.isNotEmpty ? block.linkLabel : block.url,
            style: AymaType.sans(size: 13, color: ac.accent, height: 1.35),
          ),
        ),
        // A link's own "visit it" affordance lives here, separate from the
        // row's general tap (which opens chat about this block) — a link is
        // the one block type whose primary use is leaving the app, not
        // talking about it.
        if (block.url.isNotEmpty)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => launchUrl(Uri.parse(block.url),
                mode: LaunchMode.externalApplication),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.open_in_new, size: 14, color: ac.accent),
            ),
          ),
      ],
    );
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            block.url,
            width: 72,
            height: 72,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 72,
              height: 72,
              color: ac.bgCard,
              child: Icon(Icons.broken_image_outlined, color: ac.fgMute, size: 18),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (block.isPending)
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ac.accentFaint,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('PENDING',
                      style: AymaType.mono(size: 8, color: ac.accent)
                          .copyWith(letterSpacing: 1)),
                ),
              if (block.caption.isNotEmpty)
                Text(block.caption,
                    style: AymaType.sans(size: 12.5, soft: true, color: ac.fgMute)),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoGridRow extends StatelessWidget {
  const _PhotoGridRow({required this.block});
  final ReportBlock block;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final photos = block.photos;
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            photos[i]['url'] as String? ?? '',
            width: 76,
            height: 76,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 76,
              height: 76,
              color: ac.bgCard,
              child: Icon(Icons.broken_image_outlined, color: ac.fgMute, size: 18),
            ),
          ),
        ),
      ),
    );
  }
}

/// "N selected · Chat about these / Cancel" (§ founder point 4).
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onCancel,
    required this.onChat,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: ac.bgElev,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text('$count selected',
                    style: AymaType.sans(size: 14, color: ac.fg)),
              ),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: count == 0 ? null : onChat,
                child: const Text('Chat about these'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Couldn't load that report.",
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 14, color: ac.fgMute)),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
