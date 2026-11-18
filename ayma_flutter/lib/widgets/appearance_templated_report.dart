/// The APPEARANCE report, as a designed TEMPLATED page — not the generic
/// Node-Visualiser bullet tree every other report renders through
/// ([GraphTreeView]). The founder viewed a match's appearance report and the
/// generic bullet rows read badly for it (build 2488): a face/physique analysis
/// wants a score header, its analysed photos shown like the profile carousel,
/// and its attributes laid out as fields — not a flat list of tappable bullets.
///
/// SAME source of truth, no second store: this fetches the exact appearance
/// NODE TREE the bullet tree did (`GET /report/appearance/{uid}/tree` via
/// [ApiClient.reportTree] — `report_hub.get_report('appearance', …)` over the
/// appearance graph nodes), and maps each node tree SECTION (`page_type`
/// `attributes` / `face` / `body`) to a fixed designed section populated from
/// that section's nodes. No node is duplicated or re-derived; the bullet tree
/// and this template read one and the same tree.
///
/// Photos render CAROUSEL-style (a swipeable [PageView] of the ONE shared
/// [NodeImage] `fill` renderer, the same component the profile photo carousel
/// uses), real images — never the bounded bullet-row thumbnails.
///
/// Only the appearance report uses this; deep_dive / match / shared / story
/// stay on [GraphTreeView]. Loading / error / 404-empty states mirror
/// [GraphTreeView] exactly so the screen chrome around it is unchanged.
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import 'image_viewer.dart';
import 'node_chat_window.dart';
import 'node_visualiser.dart';
import 'score_bar.dart';

/// Fixed, designed section titles for the appearance report, keyed by the node
/// tree's `page_type` (the slug of the backend section heading — see
/// `report_tree._slug` over `report_adapters.appearance_blocks`'s "Attributes"
/// / "Face" / "Body" sections). A `page_type` not listed here falls back to the
/// section's own title, so a new appearance section still renders.
const Map<String, String> _kSectionTitles = {
  'attributes': 'Physical attributes',
  'face': 'Face',
  'body': 'Physique',
};

class AppearanceTemplatedReport extends StatefulWidget {
  const AppearanceTemplatedReport({
    super.key,
    required this.reportId,
    this.api,
    this.emptyMessage = 'No appearance report yet.',
    this.onLoaded,
  });

  /// The subject uid — the appearance report's `{report_id}` is the subject's
  /// own uid (`report_hub.resolve_owner`).
  final String reportId;
  final ApiClient? api;

  /// Shown when the tree loaded but carries no renderable section.
  final String emptyMessage;

  /// Called with the loaded tree so the host can refresh adjacent chrome (the
  /// shareable card reloads off this, exactly as it did off [GraphTreeView]).
  final void Function(GraphTree tree)? onLoaded;

  @override
  State<AppearanceTemplatedReport> createState() =>
      AppearanceTemplatedReportState();
}

class AppearanceTemplatedReportState extends State<AppearanceTemplatedReport>
    with AutomaticKeepAliveClientMixin {
  late final ApiClient _api = widget.api ?? ApiClient();

  GraphTree? _tree;
  bool _loading = true;
  bool _error = false;
  bool _notFound = false; // a clean 404 (report never run)

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AppearanceTemplatedReport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reportId != widget.reportId) _load();
  }

  /// Public so the screen can refresh the body after a re-run lands.
  Future<void> reload() => _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _notFound = false;
    });
    try {
      final tree = await withColdStartRetry(
        () async => _api.reportTree('appearance', widget.reportId),
      );
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _loading = false;
      });
      widget.onLoaded?.call(tree);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _notFound = e.statusCode == 404;
          _error = e.statusCode != 404;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final ac = context.ac;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Text("Couldn't load this.",
                style: AymaType.sans(size: 13, color: ac.fgMute)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    // A section renders when it has any photo or any non-empty node.
    final sections = (_tree?.sections ?? const [])
        .where((s) => s.nodes.any((n) =>
            n.isImage || n.text.isNotEmpty || n.label.isNotEmpty))
        .toList(growable: false);
    if (_notFound || sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          widget.emptyMessage,
          key: const Key('appearance_templated_empty'),
          style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
        ),
      );
    }

    return Column(
      key: const Key('appearance_templated_report'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final section in sections)
          _AppearanceSection(
            key: Key('appearance_section_${section.pageType}'),
            section: section,
            api: _api,
          ),
      ],
    );
  }
}

/// One fixed designed section of the appearance report, built entirely from its
/// appearance node-tree section's nodes.
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({super.key, required this.section, this.api});

  final GraphTreeSection section;
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final title = _kSectionTitles[section.pageType] ??
        (section.title.isNotEmpty ? section.title : 'Appearance');

    // Classify the section's flat nodes (appearance nodes are flat roots:
    // attribute / stat / text / image — plus any image nested under a grid).
    final images = <StoryNode>[];
    for (final n in section.nodes) {
      images.addAll(n.collectImages());
    }
    StoryNode? score;
    final fields = <StoryNode>[]; // standard labelled attributes
    final findings = <StoryNode>[]; // plain narrative text (notes, strengths…)
    final bands = <StoryNode>[]; // non-numeric stat (confidence) pills
    for (final n in section.nodes) {
      if (n.isImage) continue; // shown in the carousel
      if (n.isStat) {
        if (n.statValue != null && score == null) {
          score = n; // the first numeric score is the headline
        } else {
          bands.add(n);
        }
        continue;
      }
      if (n.standard && (n.standardLabel ?? '').isNotEmpty) {
        fields.add(n);
        continue;
      }
      if (n.text.isNotEmpty) findings.add(n);
    }

    return Container(
      key: Key('appearance_section_card_${section.pageType}'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ac.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: AymaType.serif(size: 24, color: ac.fg)),
          ),
          if (score != null) ...[
            const SizedBox(height: 14),
            _ScoreHeader(node: score),
          ],
          if (images.isNotEmpty) ...[
            const SizedBox(height: 16),
            _AppearancePhotoCarousel(
              key: Key('appearance_carousel_${section.pageType}'),
              images: images,
            ),
          ],
          if (fields.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final f in fields) _FieldRow(node: f),
          ],
          if (bands.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final b in bands) _BandRow(node: b),
          ],
          if (findings.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final t in findings) _FindingRow(node: t, api: api),
          ],
        ],
      ),
    );
  }
}

/// The headline numeric score of a face/physique section — the verdict label,
/// the big value, and a flat [ScoreBar]; the basis reads quietly beneath.
class _ScoreHeader extends StatelessWidget {
  const _ScoreHeader({required this.node});

  final StoryNode node;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final value = node.statValue!;
    // A 0..10 scale unless the number is plainly a percentage (0..100).
    final max = value > 10 ? 100.0 : 10.0;
    final verdict = node.label.isNotEmpty ? node.label : 'Score';
    final shown = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                verdict,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AymaType.sans(
                    size: 16, weight: FontWeight.w600, color: ac.fg),
              ),
            ),
            const SizedBox(width: 10),
            // Scales the big number down rather than overflow when the column
            // is very narrow or the text is scaled up (layout matrix: 320px /
            // 300px split / textScale 2.0).
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      shown,
                      key: Key('appearance_score_${node.id}'),
                      style: AymaType.serif(size: 34, color: ac.accent),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Text('/ ${max.toStringAsFixed(0)}',
                          style: AymaType.sans(size: 12, color: ac.fgMute)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ScoreBar(
          key: Key('appearance_score_bar_${node.id}'),
          value: value,
          max: max,
        ),
        if (node.statBasis.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(node.statBasis,
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
          ),
      ],
    );
  }
}

/// A labelled attribute field ("Eyes: Brown") laid out as a clean two-column
/// row rather than a bullet.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.node});

  final StoryNode node;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              node.standardLabel ?? node.label,
              style: AymaType.mono(size: 10, color: ac.fgMute),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              // GIST-FIRST: the short headline by default; full value via tap.
              node.displayGist,
              style: AymaType.sans(size: 14.5, height: 1.35, color: ac.fg),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A narrative finding (a strength / note paragraph) rendered GIST-FIRST
/// (less-text-heavy Part 1): the short gist line by default, tap-in opens the
/// node chat window with the full prose — the same default/tap contract the
/// bullet-tree [NodeVisualiser] uses, so a report's walls of text collapse to
/// scannable headlines on every surface.
class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.node, this.api});

  final StoryNode node;
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return InkWell(
      key: Key('appearance_finding_${node.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => showNodeChat(
        context,
        node: node,
        surface: NodeVisualiserSurface.report,
        api: api,
        isOwner: false,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Text(
          node.displayGist,
          style: AymaType.sans(size: 14.5, height: 1.4, color: ac.fg),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// A non-numeric stat rendered as a label + a confidence band pill.
class _BandRow extends StatelessWidget {
  const _BandRow({required this.node});

  final StoryNode node;

  Color _bandColor(AymaTokens ac, String band) {
    switch (band.toLowerCase()) {
      case 'high':
        return ac.success;
      case 'medium':
        return ac.warning;
      case 'low':
        return ac.error;
      default:
        return ac.fgDim;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final text = node.statText.isNotEmpty ? node.statText : node.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(node.label.isNotEmpty ? node.label : node.text,
                style: AymaType.sans(size: 14, color: ac.fg)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _bandColor(ac, text).withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(text,
                style: AymaType.mono(size: 11, color: _bandColor(ac, text))),
          ),
        ],
      ),
    );
  }
}

/// The analysed photos of one section, shown like the profile photo carousel —
/// a swipeable square [PageView] of the ONE shared [NodeImage] `fill` renderer,
/// with page dots and a tap-to-open fullscreen gallery. Not bullet-row
/// thumbnails.
class _AppearancePhotoCarousel extends StatefulWidget {
  const _AppearancePhotoCarousel({super.key, required this.images});

  final List<StoryNode> images;

  @override
  State<_AppearancePhotoCarousel> createState() =>
      _AppearancePhotoCarouselState();
}

class _AppearancePhotoCarouselState extends State<_AppearancePhotoCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFullscreen(int index) async {
    final urls = [for (final n in widget.images) n.imageUrl];
    if (urls.isEmpty) return;
    await AymaImageViewer.openGallery(
      context,
      urls: urls,
      initialIndex: index.clamp(0, urls.length - 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final images = widget.images;
    final page = images.isEmpty ? 0 : _page.clamp(0, images.length - 1);
    final caption = images.isEmpty ? '' : images[page].imageRead;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 1,
            child: PageView.builder(
              controller: _controller,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: images.length,
              itemBuilder: (_, i) => NodeImage(
                key: Key('appearance_photo_$i'),
                node: images[i],
                fill: true,
                displayWidth: 800,
                onTap: () => _openFullscreen(i),
              ),
            ),
          ),
        ),
        if (images.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < images.length; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == page ? ac.accent : ac.lineSoft,
                    ),
                  ),
              ],
            ),
          ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              caption,
              style: AymaType.sans(size: 12.5, height: 1.35, color: ac.fgMute),
            ),
          ),
      ],
    );
  }
}
