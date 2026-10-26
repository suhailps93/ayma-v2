import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/ayma_back_button.dart';

/// Ayma's pending updates to the user's public profile text, one card per
/// section with a before/after diff. Nothing changes publicly until the user
/// taps Apply; Dismiss throws the suggestion away.
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

  Future<void> _act(ProfileProposal p, {required bool apply}) async {
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
      if (mounted) {
        setState(() => _proposals =
            _proposals?.where((x) => x.pageId != p.pageId).toList());
      }
    } on Object {
      if (mounted) {
        setState(() => _error = "Couldn't ${apply ? 'apply' : 'dismiss'} "
            'that update. Try again.');
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
        title: const Text('Suggested updates'),
      ),
      body: _loadFailed
          ? Center(
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
                  ? const Center(child: Text('No suggestions right now'))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(_error!,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error)),
                          ),
                        for (final p in list)
                          _ProposalCard(
                            proposal: p,
                            busy: _busy.contains(p.pageId),
                            onApply: () => _act(p, apply: true),
                            onDismiss: () => _act(p, apply: false),
                          ),
                      ],
                    ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.busy,
    required this.onApply,
    required this.onDismiss,
  });

  final ProfileProposal proposal;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium;
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
            for (final part in proposal.diff)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: switch (part.op) {
                  'add' => Text('+ ${part.text}',
                      style: base?.copyWith(color: scheme.primary)),
                  'remove' => Text('- ${part.text}',
                      style: base?.copyWith(
                          color: scheme.error,
                          decoration: TextDecoration.lineThrough)),
                  _ => Text(part.text, style: base),
                },
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: busy ? null : onDismiss,
                    child: const Text('Dismiss')),
                const SizedBox(width: 8),
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
          ],
        ),
      ),
    );
  }
}
