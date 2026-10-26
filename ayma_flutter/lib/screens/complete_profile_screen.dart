import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../theme.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/completeness_ring.dart';
import 'main_shell_screen.dart';
import '../widgets/ayma_back_button.dart';

/// "Complete your profile" (route `/complete-profile`). Shows the completeness
/// score, the per-section breakdown from the questionnaire tree, and routes the
/// user into an Ayma chat on a chosen topic — Ayma captures the answers herself
/// in conversation, so there is nothing to submit here.
///
/// Progressive disclosure: until Ayma knows the user's relationship intent only
/// the universal sections show; branch-specific sections stay hidden. Within the
/// visible set, sections unlock in priority order as each earlier section's
/// core questions are covered, and a section's deeper questions only appear once
/// its core is done.
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
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Complete your profile')),
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

  static const _intentLabels = {
    'casual': 'Casual',
    'long_term': 'Long-term',
    'longterm': 'Long-term',
    'marriage': 'Marriage',
    'nikah': 'Marriage',
  };

  QuestionNode? _nodeById(List<QuestionNode> list, String id) {
    for (final n in list) {
      if (n.id == id) return n;
    }
    return null;
  }

  void _discussIntent() {
    final n = _nodeById(data.completeness.next, 'relationship_intent');
    onDiscuss(
      nodeId: 'relationship_intent',
      label: n?.label.isNotEmpty == true ? n!.label : 'Relationship intent',
      prompt: n?.aymaPrompt ??
          "what kind of relationship they're actually here for",
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final c = data.completeness;
    final grouped = data.tree.byPageType;
    final intentLabel = _intentLabels[c.intent] ?? 'Long-term';

    final unlocked = c.sections.where((s) => s.unlocked).toList();
    final locked = c.sections.where((s) => !s.unlocked).toList();

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          _Header(score: c.score, complete: c.isComplete),
          const SizedBox(height: 14),
          _TunedForLine(
            intentSet: c.intentSet,
            intentLabel: intentLabel,
            onTap: _discussIntent,
          ),
          if (!c.intentSet) ...[
            const SizedBox(height: 10),
            Text(
              'More sections open up once Ayma knows what you\'re looking for.',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ],
          const SizedBox(height: 24),
          if (unlocked.isNotEmpty) ...[
            Text(
              'SECTIONS',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4),
            ),
            const SizedBox(height: 10),
            for (final s in unlocked)
              _SectionTile(
                section: s,
                nodes: grouped[s.pageType] ?? const [],
                onDiscussSection: () {
                  final nodes = grouped[s.pageType] ?? const <QuestionNode>[];
                  final target = nodes.firstWhere(
                    (n) => !n.isCovered && n.unlocked,
                    orElse: () => nodes.firstWhere(
                      (n) => !n.isCovered,
                      orElse: () => nodes.isNotEmpty
                          ? nodes.first
                          : QuestionNode(id: s.pageType, label: s.label),
                    ),
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
          ],
          if (locked.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  'UNLOCKS AS YOU GO',
                  style: AymaType.mono(size: 10, color: ac.fgMute)
                      .copyWith(letterSpacing: 1.4),
                ),
                const SizedBox(width: 10),
                Expanded(child: Divider(height: 0.5, color: ac.lineSoft)),
              ],
            ),
            const SizedBox(height: 10),
            for (final s in locked) _LockedSectionTile(section: s),
          ],
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
  const _Header({required this.score, required this.complete});

  final int score;

  /// Everything in today's question set is answered. [score] tops out below
  /// 100 even then — there's always more Ayma could learn — so this explicit
  /// flag, not a literal 100, is what drives the "done" state.
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final done = complete;
    return Row(
      children: [
        CompletenessRing(score: score, complete: complete, size: 72, stroke: 6),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                done ? "You're all caught up ✓" : 'Your profile is $score% complete',
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

/// The "who is this tuned for" line under the header. When the intent is set it
/// is a quiet "Tuned for: X" you can tap to revisit; when it isn't, it becomes
/// the prominent call to action that gets Ayma to ask.
class _TunedForLine extends StatelessWidget {
  const _TunedForLine({
    required this.intentSet,
    required this.intentLabel,
    required this.onTap,
  });

  final bool intentSet;
  final String intentLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (!intentSet) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: ac.accentFaint,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: ac.accent.withValues(alpha: 0.4), width: 0.5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Ayma is still figuring out what you want',
                  style: AymaType.sans(
                      size: 14, weight: FontWeight.w600, color: ac.fg),
                ),
              ),
              Icon(Icons.arrow_forward, size: 16, color: ac.accent),
            ],
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text('Tuned for: ',
                style: AymaType.sans(size: 13, color: ac.fgMute)),
            Text(
              intentLabel,
              style: AymaType.sans(
                  size: 13, weight: FontWeight.w600, color: ac.fg),
            ),
            const SizedBox(width: 6),
            Icon(Icons.tune, size: 14, color: ac.fgMute),
          ],
        ),
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

  Widget _nodeRow(BuildContext context, QuestionNode n) {
    final ac = context.ac;
    return Padding(
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
                child:
                    Icon(Icons.forum_outlined, size: 15, color: ac.accent),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = widget.section;
    final core = widget.nodes.where((n) => n.isCore).toList();
    final deep = widget.nodes.where((n) => !n.isCore).toList();
    final showDeep = s.coreComplete;
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
                  for (final n in core) _nodeRow(context, n),
                  if (deep.isNotEmpty && showDeep)
                    for (final n in deep) _nodeRow(context, n),
                  if (deep.isNotEmpty && !showDeep)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline,
                              size: 13, color: ac.fgMute),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'More detail unlocks after the basics.',
                              style: AymaType.sans(
                                  size: 12, soft: true, color: ac.fgMute),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (widget.nodes.isEmpty)
                    Text(
                      'Nothing else here right now.',
                      style: AymaType.sans(
                          size: 12, soft: true, color: ac.fgMute),
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

/// A section that isn't open yet: dimmed, a lock icon, no progress bar, and not
/// expandable. Shown at the bottom under the "Unlocks as you go" divider.
class _LockedSectionTile extends StatelessWidget {
  const _LockedSectionTile({required this.section});

  final CompletenessSection section;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Opacity(
      opacity: 0.55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: ac.fgMute),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                section.label,
                style: AymaType.sans(size: 14, color: ac.fg),
              ),
            ),
            Text('Locked', style: AymaType.mono(size: 10, color: ac.fgMute)),
          ],
        ),
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
    return CenteredScroll(
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
    );
  }
}
