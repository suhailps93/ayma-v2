/// Fetch-and-render host for a person-graph tree surface (2o — Node-Visualiser
/// adoption). Loads `GET /profile/graph/tree` for one surface and renders every
/// section through the ONE shared [NodeVisualiserSection], with loading / error
/// / empty states. This is the embeddable replacement for the old block-model
/// renderer on the node-backed surfaces (Your Story, public profile); a report
/// surface uses it once the report→node work lands.
///
/// Returns a non-scrolling Column (mainAxisSize.min) so it drops straight into
/// a host's own ListView/Column, exactly where the old renderer sat.
library;

import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import 'node_visualiser.dart';

class GraphTreeView extends StatefulWidget {
  const GraphTreeView({
    super.key,
    this.uid,
    required this.surface,
    this.reportType,
    this.reportId,
    this.loader,
    this.api,
    this.isOwner = true,
    this.emptyMessage = 'Nothing here yet.',
    this.emptyBuilder,
    this.onImageTap,
    this.onCandidateVerdict,
    this.onLoaded,
  });

  /// Whose graph to load — null means the signed-in user ("mine"). Ignored when
  /// [reportType] is set (a report is fetched by type+id, not by uid).
  final String? uid;

  /// The surface (sets the visibility filter + owner affordances).
  final NodeVisualiserSurface surface;

  /// When set, the body is a REPORT tree fetched via
  /// `ApiClient.reportTree(reportType, reportId)` (2o P2) instead of the person
  /// graph — the appearance / deep-dive / match / shared report screens.
  final String? reportType;
  final String? reportId;

  /// When set, the tree is fetched by this callback instead of by
  /// [reportType]/[reportId] or [uid] — the token-scoped shared-report path
  /// (`ApiClient.sharedReportTree`, 2o P5). That read carries no auth and MUST
  /// NOT go through the owner-checked `/report/.../tree`, so the shared screen
  /// hands its own unauthenticated loader here. A thrown [ApiException] keeps
  /// the same 404-is-empty / other-is-error handling as the report path.
  final Future<GraphTree> Function()? loader;

  final ApiClient? api;

  /// Whether the viewer owns this graph (owner action bubbles show only then).
  final bool isOwner;

  /// Shown when the tree loaded but has no visible content.
  final String emptyMessage;

  /// A rich empty state — shown instead of [emptyMessage] when the report has
  /// never been run (a clean 404) or the tree is empty (e.g. deep-dive's "Run
  /// web search" CTA).
  final WidgetBuilder? emptyBuilder;

  /// Overrides what tapping an image node does (e.g. the carousel's viewer).
  final void Function(StoryNode node)? onImageTap;

  /// A CANDIDATE node's "This is me" / "Not me" verdict (deep-dive report).
  final void Function(StoryNode node, bool isMe)? onCandidateVerdict;

  /// Called with the loaded tree (e.g. so a host can refresh adjacent chrome).
  final void Function(GraphTree tree)? onLoaded;

  @override
  State<GraphTreeView> createState() => GraphTreeViewState();
}

class GraphTreeViewState extends State<GraphTreeView>
    with AutomaticKeepAliveClientMixin {
  late final ApiClient _api = widget.api ?? ApiClient();

  GraphTree? _tree;
  bool _loading = true;
  bool _error = false;
  bool _notFound = false; // a clean 404 (report never run) → empty CTA

  // Survive flings when embedded in a scrolling host (e.g. Your Story's outer
  // ListView): without this the widget is destroyed + re-fetched on every
  // scroll-in during a rapid fling, the re-fetch-storm ANR (NOTE 232) the old
  // BulletSectionsEditor hit and fixed the same way.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant GraphTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid ||
        oldWidget.surface != widget.surface ||
        oldWidget.reportType != widget.reportType ||
        oldWidget.reportId != widget.reportId) {
      _load();
    }
  }

  /// Public so a host (e.g. after an edit elsewhere, or a report re-run) can
  /// refresh the tree.
  Future<void> reload() => _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _notFound = false;
    });
    try {
      final tree = await withColdStartRetry(
        () async => widget.loader != null
            ? await widget.loader!()
            : widget.reportType != null
                ? await _api.reportTree(
                    widget.reportType!, widget.reportId ?? '')
                : await _api.graphTree(
                    uid: widget.uid, surface: widget.surface.name),
      );
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _loading = false;
      });
      widget.onLoaded?.call(tree);
    } on ApiException catch (e) {
      // A clean 404 means the report has never been run — a CTA empty state,
      // not the "Couldn't load" error a real fetch failure gets.
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

    final sections = _tree?.sections
            .where((s) => s.nodes.isNotEmpty)
            .toList(growable: false) ??
        const [];
    if (_notFound || sections.isEmpty) {
      if (widget.emptyBuilder != null) return widget.emptyBuilder!(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          widget.emptyMessage,
          key: const Key('graph_tree_empty'),
          style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
        ),
      );
    }

    // On a REPORT surface every section renders as a designed card (the one
    // visual report framework, founder Nov 17) — scores, photos, findings and
    // facts all assembled from the nodes' own palette visuals. Your Story /
    // public profile / graph detail keep the plain heading + rows.
    final cardStyle = widget.surface == NodeVisualiserSurface.report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, section) in sections.indexed)
          NodeVisualiserSection(
            // Index-keyed: a surface can carry two sections of the same
            // page_type, so the page_type alone is not unique.
            key: Key('graph_section_${i}_${section.pageType}'),
            section: section,
            surface: widget.surface,
            api: _api,
            isOwner: widget.isOwner,
            onChanged: _load,
            onImageTap: widget.onImageTap,
            onCandidateVerdict: widget.onCandidateVerdict,
            cardStyle: cardStyle,
          ),
      ],
    );
  }
}
