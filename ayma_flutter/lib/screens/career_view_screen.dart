import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/node_visualiser.dart';
import '../widgets/overflow_guards.dart';

/// "Career & education" — the dedicated Career view (founder Nov 17, "B-widened").
///
/// A single, editable LIST over the person-graph Career section and ALL its
/// existing children at run time: the career seed nodes (role / trajectory /
/// integration / work-schedule / education), the public LinkedIn link node, and
/// any emergent career children the graph has grown. It renders LinkedIn/career
/// timeline-style — a date beside an entry ONLY where that node already carries
/// one ([StoryNode.dated], the first `Link.dated` on it). Entries without a date
/// list with no date; NO date field is ever invented and no node is migrated
/// (there is no career-timeline schema — the deleted wiki-timeline subsystem
/// stays deleted).
///
/// Editing reuses the generic Node-Visualiser paths unchanged: every entry is a
/// real [NodeVisualiser], so tapping it opens the node chat window with the same
/// set-answer / visibility / add-child / delete affordances that drive
/// `/profile/graph/node/*`. This screen adds a presentation, never a second data
/// model.
class CareerViewScreen extends StatefulWidget {
  const CareerViewScreen({super.key, this.api});

  static const path = '/profile/career';

  final ApiClient? api;

  @override
  State<CareerViewScreen> createState() => _CareerViewScreenState();
}

class _CareerViewScreenState extends State<CareerViewScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  GraphTree? _tree;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The Career section's root nodes — the one section this view is over.
  List<StoryNode> get _careerNodes {
    for (final s in _tree?.sections ?? const <GraphTreeSection>[]) {
      if (s.pageType == 'career') return s.nodes;
    }
    return const [];
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final tree = await withColdStartRetry(
        () async => _api.graphTree(surface: NodeVisualiserSurface.story.name),
      );
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _loading = false;
      });
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
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Career & education'),
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final ac = context.ac;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error) {
      return CenteredScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Couldn't load your career.",
                style: AymaType.sans(size: 14, color: ac.fgMute)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final nodes = _careerNodes;
    if (nodes.isEmpty) {
      return CenteredScroll(
        child: Text(
          'Nothing in your career yet. Tell Ayma what you do — your role, where '
          'your work is headed, your education — and it shows up here.',
          key: const Key('career_empty'),
          textAlign: TextAlign.center,
          style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        Text(
          'Your work and education, as Ayma knows it. Tap any entry to change '
          'it, make it public or private, or add to it.',
          style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
        ),
        const SizedBox(height: 8),
        for (final node in nodes)
          _CareerEntry(
            key: Key('career_entry_${node.id}'),
            node: node,
            api: _api,
            onChanged: _load,
          ),
      ],
    );
  }
}

/// One timeline entry: the node's date (only when it already carries one) above
/// the node itself, which renders through the shared [NodeVisualiser] so all
/// editing flows through the generic node-edit paths.
class _CareerEntry extends StatelessWidget {
  const _CareerEntry({
    super.key,
    required this.node,
    required this.api,
    required this.onChanged,
  });

  final StoryNode node;
  final ApiClient api;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final dated = node.dated.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dated.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_outlined, size: 13, color: ac.fgDim),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      dated,
                      key: Key('career_date_${node.id}'),
                      style: AymaType.mono(size: 11, color: ac.fgDim),
                    ),
                  ),
                ],
              ),
            ),
          NodeVisualiser(
            node: node,
            surface: NodeVisualiserSurface.story,
            api: api,
            onChanged: onChanged,
          ),
          Divider(height: 18, thickness: 0.5, color: ac.lineSoft),
        ],
      ),
    );
  }
}
