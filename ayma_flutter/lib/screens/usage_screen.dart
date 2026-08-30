import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Token usage — how much Gemini the account has spent across chat, voice,
/// icebreakers and matching, against the per-user cap.
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
      appBar: AppBar(title: const Text('Usage')),
      body: RefreshIndicator(
        onRefresh: () async => setState(() => _future = _api.usage()),
        child: FutureBuilder<UsageSummary>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load usage (${snap.error}).',
                      style:
                          AymaType.sans(size: 14, color: AymaColors.error)),
                ),
              ]);
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final u = snap.data!;
            final entries = u.features.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              children: [
                Text(
                  '${_fmt(u.total)} of ${_fmt(u.cap)} tokens',
                  style: AymaType.serif(size: 24, color: ac.fg),
                ),
                const SizedBox(height: 4),
                Text(
                  u.atCap
                      ? "You've reached the limit — it frees up over time."
                      : '${_fmt(u.remaining)} left',
                  style: AymaType.sans(
                      size: 13,
                      color: u.atCap ? AymaColors.error : ac.fgMute),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: u.fraction,
                    minHeight: 10,
                    backgroundColor: ac.bgCard,
                    valueColor: AlwaysStoppedAnimation(
                        u.atCap ? AymaColors.error : ac.accent),
                  ),
                ),
                const SizedBox(height: 28),
                Text('Breakdown',
                    style: AymaType.mono(size: 11, color: ac.fgMute)),
                const SizedBox(height: 8),
                if (entries.isEmpty)
                  Text('Nothing used yet.',
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
                          Text(_fmt(e.value),
                              style: AymaType.mono(
                                  size: 12, color: ac.fgMute)),
                        ],
                      ),
                    ),
                const SizedBox(height: 24),
                Text(
                  'Counts every Gemini call your activity drives — Ayma’s text '
                  'and voice replies, icebreaker suggestions, and the '
                  'matchmaking agent.',
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
