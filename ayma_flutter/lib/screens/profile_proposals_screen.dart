import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/overflow_guards.dart';

/// Ayma's pending updates to the user's PUBLIC profile, grouped by section.
/// Each added or removed sentence is its own row with its own Apply and
/// Dismiss, so the user decides sentence-by-sentence what shows publicly.
/// Apply puts a change on the public profile; Dismiss keeps it private — Ayma
/// still remembers it. Nothing changes until a row is tapped.
class ProfileProposalsScreen extends StatefulWidget {
  const ProfileProposalsScreen({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  State<ProfileProposalsScreen> createState() => _ProfileProposalsScreenState();
}

class _ProfileProposalsScreenState extends State<ProfileProposalsScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  List<ProfileProposal>? _proposals;
  bool _loadFailed = false;
  // Keyed by "pageId/changeId" (per-change rows) and pageId (section-wide
  // Apply all / Dismiss all) so each spinner is independent.
  final Set<String> _busy = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      final list = await _api.profileProposals();
      if (mounted) setState(() => _proposals = list);
    } on Object {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// Drop the decided change(s) locally; remove a section once it is empty.
  void _remove(String pageId, {String? changeId}) {
    final next = <ProfileProposal>[];
    for (final p in _proposals ?? const <ProfileProposal>[]) {
      if (p.pageId != pageId) {
        next.add(p);
        continue;
      }
      if (changeId == null) continue; // section cleared wholesale
      final changes =
          p.changes.where((c) => c.id != changeId).toList(growable: false);
      if (changes.isNotEmpty) {
        next.add(ProfileProposal(
            pageId: p.pageId, title: p.title, changes: changes));
      }
    }
    _proposals = next;
  }

  Future<void> _actChange(ProfileProposal p, ProfileChange c,
      {required bool apply}) async {
    final key = '${p.pageId}/${c.id}';
    if (_busy.contains(key)) return;
    setState(() {
      _busy.add(key);
      _error = null;
    });
    try {
      if (apply) {
        await _api.profileChangeApply(p.pageId, c.id);
      } else {
        await _api.profileChangeDismiss(p.pageId, c.id);
      }
      if (mounted) setState(() => _remove(p.pageId, changeId: c.id));
    } on Object {
      if (mounted) {
        setState(() => _error = "Couldn't ${apply ? 'apply' : 'dismiss'} "
            'that change. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _actSection(ProfileProposal p, {required bool apply}) async {
    if (_busy.contains(p.pageId)) return;
    setState(() {
      _busy.add(p.pageId);
      _error = null;
    });
    try {
      if (apply) {
        await _api.profileProposalApply(p.pageId);
      } else {
        await _api.profileProposalDismiss(p.pageId);
      }
      if (mounted) setState(() => _remove(p.pageId));
    } on Object {
      if (mounted) {
        setState(() => _error = "Couldn't ${apply ? 'apply' : 'dismiss'} "
            'those changes. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy.remove(p.pageId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _proposals;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Public profile updates'),
      ),
      body: _loadFailed
          ? CenteredScroll(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Couldn't load the suggestions."),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : list == null
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const CenteredScroll(
                      padding: EdgeInsets.all(24),
                      child: Text('No suggestions right now'),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const _IntroCard(),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(_error!,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error)),
                          ),
                        for (final p in list)
                          _SectionCard(
                            proposal: p,
                            busy: _busy,
                            onApplyChange: (c) =>
                                _actChange(p, c, apply: true),
                            onDismissChange: (c) =>
                                _actChange(p, c, apply: false),
                            onApplyAll: () => _actSection(p, apply: true),
                            onDismissAll: () => _actSection(p, apply: false),
                          ),
                      ],
                    ),
    );
  }
}

/// The one-line explainer at the top of the list: what Apply and Dismiss do.
class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        'What Ayma suggests adding to your public profile. Apply shows it on '
        'your public profile; Dismiss keeps it private — Ayma still remembers '
        'it.',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.proposal,
    required this.busy,
    required this.onApplyChange,
    required this.onDismissChange,
    required this.onApplyAll,
    required this.onDismissAll,
  });

  final ProfileProposal proposal;
  final Set<String> busy;
  final void Function(ProfileChange) onApplyChange;
  final void Function(ProfileChange) onDismissChange;
  final VoidCallback onApplyAll;
  final VoidCallback onDismissAll;

  @override
  Widget build(BuildContext context) {
    final sectionBusy = busy.contains(proposal.pageId);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(proposal.title,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final c in proposal.changes)
              _ChangeRow(
                change: c,
                // A section-wide action busies every row too.
                busy: sectionBusy || busy.contains('${proposal.pageId}/${c.id}'),
                onApply: () => onApplyChange(c),
                onDismiss: () => onDismissChange(c),
              ),
            if (proposal.changes.length > 1) ...[
              const Divider(height: 24),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                        onPressed: sectionBusy ? null : onDismissAll,
                        child: const Text('Dismiss all')),
                    TextButton(
                        onPressed: sectionBusy ? null : onApplyAll,
                        child: const Text('Apply all')),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.change,
    required this.busy,
    required this.onApply,
    required this.onDismiss,
  });

  final ProfileChange change;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium;
    // Diff colours from `suggested-diff-colors`: removed is red strikethrough,
    // added is a muted gray (`onSurfaceVariant`), in both themes.
    final isRemove = change.op == 'remove';
    final style = isRemove
        ? base?.copyWith(
            color: scheme.error, decoration: TextDecoration.lineThrough)
        : base?.copyWith(color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${isRemove ? '- ' : '+ '}${change.text}', style: style),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                    onPressed: busy ? null : onDismiss,
                    child: const Text('Dismiss')),
                // The app theme gives FilledButton a full-width minimum size;
                // inside a Row that is an infinite width, which fails layout
                // and left this whole screen blank (build 2208).
                FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44)),
                    onPressed: busy ? null : onApply,
                    child: const Text('Apply')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
