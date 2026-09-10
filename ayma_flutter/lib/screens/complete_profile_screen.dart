import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../theme.dart';
import '../widgets/completeness_ring.dart';
import 'main_shell_screen.dart';

/// "Complete your profile" (route `/complete-profile`). Shows the completeness
/// score, the per-section breakdown from the questionnaire tree, and routes the
/// user into an Ayma chat on a chosen topic — Ayma captures the answers herself
/// in conversation, so there is nothing to submit here.
class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({super.key, this.apiClient});

  static const path = '/complete-profile';

  final ApiClient? apiClient;

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteData {
  const _CompleteData(this.completeness, this.tree);
  final Completeness completeness;
  final QuestionnaireTree tree;
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late Future<_CompleteData> _future = _fetch();

  Future<_CompleteData> _fetch() async {
    final results = await Future.wait([
      _api.completeness(),
      _api.questionnaireTree(),
    ]);
    return _CompleteData(
      results[0] as Completeness,
      results[1] as QuestionnaireTree,
    );
  }

  Future<void> _reload() async {
    final next = _fetch();
    setState(() => _future = next);
    try {
      await next;
    } catch (_) {/* surfaced by the FutureBuilder's error branch */}
  }

  /// Hand a topic to the Ayma chat and jump to the shell's Ayma tab.
  void _discuss({required String nodeId, required String label, String prompt = ''}) {
    ChatInbox.instance.push(ChatKickoff.discussTopic(
      nodeId: nodeId,
      label: label,
      prompt: prompt,
    ));
    context.go(MainShellScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete your profile')),
      body: FutureBuilder<_CompleteData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null) {
            return _Message(
              text: "Couldn't load your profile progress.",
              onRetry: () => setState(() => _future = _fetch()),
            );
          }
          return _Body(
            data: snap.data!,
            onRefresh: _reload,
            onDiscuss: _discuss,
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.data,
    required this.onRefresh,
    required this.onDiscuss,
  });

  final _CompleteData data;
  final Future<void> Function() onRefresh;
  final void Function({required String nodeId, required String label, String prompt}) onDiscuss;

  QuestionNode? _nodeById(List<QuestionNode> list, String id) {
    for (final n in list) {
      if (n.id == id) return n;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final c = data.completeness;
    final grouped = data.tree.byPageType;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          if (!c.intentSet) ...[
            _IntentCallout(
              onTap: () {
                final n = _nodeById(c.next, 'relationship_intent');
                onDiscuss(
                  nodeId: 'relationship_intent',
                  label: n?.label.isNotEmpty == true
                      ? n!.label
                      : 'Relationship intent',
                  prompt: n?.aymaPrompt ??
                      "what kind of relationship they're actually here for",
                );
              },
            ),
            const SizedBox(height: 20),
          ],
          _Header(score: c.score),
          const SizedBox(height: 24),
          Text(
            'SECTIONS',
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.4),
          ),
          const SizedBox(height: 10),
          for (final s in c.sections)
            _SectionTile(
              section: s,
              nodes: grouped[s.pageType] ?? const [],
              onDiscussSection: () {
                final nodes = grouped[s.pageType] ?? const [];
                final target = nodes.firstWhere(
                  (n) => !n.isCovered,
                  orElse: () => nodes.isNotEmpty
                      ? nodes.first
                      : QuestionNode(id: s.pageType, label: s.label),
                );
                onDiscuss(
                  nodeId: target.id,
                  label: s.label,
                  prompt: target.aymaPrompt,
                );
              },
              onDiscussNode: (n) => onDiscuss(
                nodeId: n.id,
                label: n.label,
                prompt: n.aymaPrompt,
              ),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => onDiscuss(nodeId: '', label: '', prompt: ''),
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: const Text('Talk it through with Ayma'),
          ),
          const SizedBox(height: 16),
          Text(
            'Ayma fills these in as you talk — there\'s nothing to submit here. '
            'A fuller profile means more accurate matches and a wider pool.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final done = score >= 100;
    return Row(
      children: [
        CompletenessRing(score: score, size: 72, stroke: 6),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                done ? 'Profile complete ✓' : 'Your profile is $score% complete',
                style: AymaType.serif(size: 21, color: ac.fg),
              ),
              const SizedBox(height: 6),
              Text(
                done
                    ? 'Ayma keeps refining your matches as she learns more.'
                    : 'Complete it for more accurate matches and a better '
                        'match pool.',
                style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.45),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IntentCallout extends StatelessWidget {
  const _IntentCallout({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.accentFaint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.accent.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'First: tell Ayma what you\'re looking for',
            style: AymaType.sans(size: 15, weight: FontWeight.w600, color: ac.fg),
          ),
          const SizedBox(height: 6),
          Text(
            'Your relationship intent shapes everything else Ayma asks and every '
            'match she sources.',
            style: AymaType.sans(size: 12, color: ac.fgDim, height: 1.45),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onTap,
            child: const Text('Talk to Ayma about this'),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatefulWidget {
  const _SectionTile({
    required this.section,
    required this.nodes,
    required this.onDiscussSection,
    required this.onDiscussNode,
  });

  final CompletenessSection section;
  final List<QuestionNode> nodes;
  final VoidCallback onDiscussSection;
  final void Function(QuestionNode) onDiscussNode;

  @override
  State<_SectionTile> createState() => _SectionTileState();
}

class _SectionTileState extends State<_SectionTile> {
  bool _expanded = false;

  double get _fraction {
    final s = widget.section;
    if (s.total > 0) return (s.answered / s.total).clamp(0.0, 1.0);
    return (s.pct / 100.0).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = widget.section;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.label,
                                style: AymaType.sans(size: 14, color: ac.fg),
                              ),
                            ),
                            Text(
                              s.total > 0
                                  ? '${s.answered}/${s.total}'
                                  : '${s.pct}%',
                              style: AymaType.mono(size: 10, color: ac.fgMute),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _Bar(fraction: _fraction),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: ac.fgMute,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 0.5, color: ac.lineSoft),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final n in widget.nodes)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: _StatusDot(status: n.status),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              n.label,
                              style: AymaType.sans(
                                size: 13,
                                color: n.isCovered ? ac.fgMute : ac.fg,
                              ),
                            ),
                          ),
                          if (!n.isCovered)
                            InkWell(
                              onTap: () => widget.onDiscussNode(n),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(Icons.forum_outlined,
                                    size: 15, color: ac.accent),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (widget.nodes.isEmpty)
                    Text(
                      'Nothing else here right now.',
                      style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                    ),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: widget.onDiscussSection,
                    icon: const Icon(Icons.forum_outlined, size: 15),
                    label: const Text('Talk to Ayma about this'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        children: [
          Container(height: 5, color: ac.lineSoft),
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: Container(color: ac.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final covered = status == 'covered';
    final partial = status == 'partial';
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: covered
            ? ac.accent
            : partial
                ? ac.accent.withValues(alpha: 0.4)
                : Colors.transparent,
        border: Border.all(
          color: covered || partial ? ac.accent : ac.fgMute,
          width: 1.2,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, color: ac.fgMute),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
