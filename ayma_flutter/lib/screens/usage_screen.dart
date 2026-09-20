import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/ayma_session.dart';
import '../services/credits_balance.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';

/// Credits — the account's spendable balance and a per-feature breakdown of
/// where they went, in credits only. Deliberately no raw token counts or
/// dollar figures here — that's for the founder's admin dashboard, not the
/// user-facing screen (§ founder: "just show credits and the usage of
/// credits, not exact tokens or usage amount in dollars").
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, this.api});

  static const path = '/profile/usage';

  final ApiClient? api;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  Future<UsageSummary>? _future;
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  // Publishes into the shared CreditsBalance every time this screen fetches
  // /usage — the Profile tab's own credit-balance row fetches once and is
  // never rebuilt after (kept alive in the tab shell), so without this it
  // would keep showing a stale number after any reload here (§ founder
  // report: real balance 83, tab row stuck on 0 from before the first
  // top-up).
  Future<UsageSummary> _fetch() async {
    final u = await _api.usage();
    CreditsBalance.instance.remaining.value = u.creditsRemaining;
    return u;
  }

  Future<void> _reload() async {
    if (_reloading) return;
    setState(() => _reloading = true);
    try {
      final updated = await _api.topUpCredits();
      if (!mounted) return;
      CreditsBalance.instance.remaining.value = updated.creditsRemaining;
      setState(() {
        _future = Future.value(updated);
      });
      // Clears a stale "Out of credits" voice banner left over from before
      // this top-up — see VoiceSessionController.clearCappedError.
      AymaSession.instance.voice.clearCappedError();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Credits reloaded — ${updated.creditsRemaining} left.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't reload credits ($e).")),
        );
      }
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  static const _labels = {
    'chat': 'Text chat with Ayma',
    'voice': 'Voice with Ayma',
    'icebreakers': 'Icebreakers',
    'matching': 'Match scoring',
    'wiki': 'Building your wiki',
    'explore': 'Explore search',
    'reengage': 'Ayma checking in',
    'photos': 'Reading your photos',
    'dm': 'Message notes',
    'lint': 'Wiki housekeeping',
    'misc': 'Other',
  };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Credits')),
      body: RefreshIndicator(
        onRefresh: () async {
          if (mounted) {
            setState(() {
              _future = _fetch();
            });
          }
        },
        child: FutureBuilder<UsageSummary>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load credits (${snap.error}).',
                      style:
                          AymaType.sans(size: 14, color: AymaColors.error)),
                ),
              ]);
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final u = snap.data!;
            final out = u.creditsRemaining == 0;
            final entries = u.features.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${u.creditsRemaining}',
                        style: AymaType.serif(
                            size: 44,
                            color: out ? AymaColors.error : ac.fg)),
                    Text('  credits left',
                        style: AymaType.sans(size: 15, color: ac.fgMute)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: ac.accentFaint,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: ac.accentSoft, width: 0.5),
                      ),
                      child: Text('FREE PLAN',
                          style: AymaType.mono(size: 9, color: ac.accent)
                              .copyWith(letterSpacing: 1.5)),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      out
                          ? 'Out of credits — reload below'
                          : '${u.creditsUsed} spent so far',
                      style: AymaType.sans(
                          size: 12,
                          color: out ? AymaColors.error : ac.fgMute),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _reloading ? null : _reload,
                  icon: _reloading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Reload credits'),
                ),
                const SizedBox(height: 4),
                Text('Free while Ayma is in beta — no charge.',
                    style: AymaType.sans(
                        size: 11, soft: true, color: ac.fgMute)),
                const SizedBox(height: 24),
                const Eyebrow('Where they went'),
                const SizedBox(height: 10),
                if (entries.isEmpty)
                  Text('Nothing spent yet.',
                      style: AymaType.sans(
                          size: 14, soft: true, color: ac.fgMute))
                else
                  for (final e in entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(_labels[e.key] ?? e.key,
                                style: AymaType.sans(
                                    size: 14, color: ac.fg)),
                          ),
                          Text('${u.creditsForFeature(e.value)} cr',
                              style: AymaType.mono(
                                  size: 12, color: ac.fgDim)),
                        ],
                      ),
                    ),
                const SizedBox(height: 24),
                Text(
                  'Credits cover every call your activity drives — Ayma’s '
                  'text and voice replies, icebreakers, and match scoring.',
                  style: AymaType.sans(
                      size: 12, soft: true, color: ac.fgMute),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
