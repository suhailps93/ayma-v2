import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';

/// Credits — the account's spendable balance (a display layer over Gemini
/// tokens) with a breakdown of where they went across chat, voice, icebreakers
/// and matchmaking.
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

  @override
  void initState() {
    super.initState();
    _future = _api.usage();
  }

  static const _labels = {
    'chat': 'Text chat with Ayma',
    'voice': 'Voice with Ayma',
    'icebreakers': 'Icebreakers',
    'matching': 'Matchmaking',
    'wiki': 'Building your wiki',
    'misc': 'Other',
  };

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Credits')),
      body: RefreshIndicator(
        onRefresh: () async => setState(() => _future = _api.usage()),
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
                        style: AymaType.serif(size: 44, color: ac.fg)),
                    Text('  / ${u.creditGrant} credits',
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
                          ? 'Out of credits — frees up over time'
                          : '${u.creditsUsed} spent so far',
                      style: AymaType.sans(
                          size: 12,
                          color: out ? AymaColors.error : ac.fgMute),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: u.creditFraction,
                    minHeight: 10,
                    backgroundColor: ac.bgCard,
                    valueColor: AlwaysStoppedAnimation(
                        out ? AymaColors.error : ac.accent),
                  ),
                ),
                const SizedBox(height: 28),
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
                          const SizedBox(width: 8),
                          Text('${_fmt(e.value)} tok',
                              style: AymaType.mono(
                                  size: 10, color: ac.fgMute)),
                        ],
                      ),
                    ),
                const SizedBox(height: 24),
                Text(
                  '1 credit ≈ ${_fmt(u.tokensPerCredit)} Gemini tokens. Credits '
                  'cover every call your activity drives — Ayma’s text and '
                  'voice replies, icebreakers, and match scoring.',
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
