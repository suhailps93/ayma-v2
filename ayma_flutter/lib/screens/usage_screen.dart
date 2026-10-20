import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/ayma_session.dart';
import '../services/credits_balance.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';
import 'plans_screen.dart';

/// Credits — two tabs. "Credits": the account's spendable balance and a
/// per-feature breakdown of where they went, in credits only (never raw
/// tokens — § founder: "just show credits and the usage of credits").
/// "Dev view" (founder/dev allowlist only — the server sends `is_dev` and
/// withholds every dollar field from everyone else): what the account's
/// usage actually cost in dollars, plus a free reload, per
/// conversation, starting from $0.00 when tracking began (§ founder,
/// 2026-09-26: "I want to know exactly how much did I spend in real money
/// for each conversation even if those tokens come free from Google").
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
  bool _resettingMoney = false;
  String _tab = 'credits'; // 'credits' | 'dev' (dev only)

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
      // Same for any "Reload credits" prompt(s) still sitting in the chat
      // transcript from before this top-up — see
      // TranscriptStore.clearCappedTurns.
      AymaSession.instance.store.clearCappedTurns();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Credits reloaded — ${updated.creditsRemaining} left.')),
      );
    } on UpgradeRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _reloading = false); // stop the spinner behind the dialog
      await _showUpgrade(e.message);
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

  // Shows the server's upgrade message with a route to the plans screen.
  Future<void> _showUpgrade(String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('upgrade-dialog'),
        title: const Text('Upgrade for more credits'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.push(PlansScreen.path);
              },
              child: const Text('See plans')),
        ],
      ),
    );
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

  /// What a background spend group was, by its dominant feature — the "Real
  /// money" tab's row titles (voice/chat groups get their own titles).
  static const _moneyLabels = {
    'wiki': 'Wiki update',
    'summary': 'Conversation summary',
    'completeness': 'Profile completeness',
    'icebreakers': 'Icebreakers',
    'matching': 'Match scoring',
    'explore': 'Explore search',
    'reengage': 'Ayma checking in',
    'deepdive': 'Web research',
    'face_report': 'Face report',
    'body_report': 'Body report',
    'physical_attrs': 'Reading your photos',
    'photo_attrs': 'Reading your photos',
    'photo_caption': 'Photo notes',
    'photo_moderation': 'Photo safety check',
    'dm_ingest': 'Reading messages',
    'career_timeline': 'Career timeline',
    'photo_edit': 'Photo edit',
    'persona_evolution': 'Persona tuning',
  };

  /// Dollars, to the cent — with sub-cent precision where the figure would
  /// otherwise vanish (e.g. `$0.0154`), and plain cents once it's real money
  /// (`$1.06`). `$0.00` exactly at zero.
  static String _usd(double v) => v > 0 && v < 0.10
      ? '\$${v.toStringAsFixed(4)}'
      : '\$${v.toStringAsFixed(2)}';

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// `Sep 26` — the reset sub-line's date.
  static String _date(DateTime t) => '${_months[t.month - 1]} ${t.day}';

  /// Confirm → `POST /usage/reset-real-money` → swap in the fresh view. The
  /// tracker restarts at $0.00; all-time and the conversation history keep
  /// counting (the endpoint writes a marker, never deletes anything).
  Future<void> _resetMoneyTracker() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset the money tracker?'),
        content: const Text(
          'The tracker goes back to \$0.00 from now. All time keeps '
          'counting, and past conversations stay listed.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _resettingMoney = true);
    try {
      final updated = await _api.resetRealMoney();
      if (!mounted) return;
      CreditsBalance.instance.remaining.value = updated.creditsRemaining;
      setState(() {
        _future = Future.value(updated);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Money tracker reset to \$0.00.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't reset the money tracker ($e).")),
        );
      }
    } finally {
      if (mounted) setState(() => _resettingMoney = false);
    }
  }

  static String _when(SpendGroup g) {
    final t = g.lastTs?.toLocal();
    if (t == null) return g.day;
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ampm = t.hour < 12 ? 'am' : 'pm';
    final mm = t.minute.toString().padLeft(2, '0');
    return '${_months[t.month - 1]} ${t.day} · $h:$mm $ampm';
  }

  static String _groupTitle(SpendGroup g) {
    if (g.kind == 'voice') {
      return 'Voice call · ${g.events} ${g.events == 1 ? 'turn' : 'turns'}';
    }
    if (g.kind == 'chat') return 'Chat with Ayma';
    String? top;
    var best = -1.0;
    g.features.forEach((k, v) {
      if (v > best) {
        best = v;
        top = k;
      }
    });
    return _moneyLabels[top] ?? 'Background work';
  }

  @override
  Widget build(BuildContext context) {
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
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              children: [
                if (u.isDev) ...[
                  _SpendTabBar(
                    view: _tab,
                    onChanged: (v) => setState(() => _tab = v),
                  ),
                  const SizedBox(height: 22),
                ],
                if (_tab == 'credits' || !u.isDev)
                  ..._creditsChildren(context, u)
                else
                  ..._realMoneyChildren(context, u),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _creditsChildren(BuildContext context, UsageSummary u) {
    final ac = context.ac;
    final out = u.creditsRemaining == 0;
    final entries = u.features.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('${u.creditsRemaining}',
              style: AymaType.serif(
                  size: 44, color: out ? AymaColors.error : ac.fg)),
          Text('  credits left',
              style: AymaType.sans(size: 15, color: ac.fgMute)),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                size: 12, color: out ? AymaColors.error : ac.fgMute),
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
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('upgrade-plans'),
        onPressed: () => context.push(PlansScreen.path),
        icon: const Icon(Icons.workspace_premium_outlined, size: 18),
        label: const Text('Upgrade'),
      ),
      const SizedBox(height: 4),
      Text('Your daily credits refresh every day.',
          style: AymaType.sans(size: 11, soft: true, color: ac.fgMute)),
      const SizedBox(height: 24),
      const Eyebrow('Where they went'),
      const SizedBox(height: 10),
      if (entries.isEmpty)
        Text('Nothing spent yet.',
            style: AymaType.sans(size: 14, soft: true, color: ac.fgMute))
      else
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(_labels[e.key] ?? e.key,
                      style: AymaType.sans(size: 14, color: ac.fg)),
                ),
                Text('${u.creditsForFeature(e.value)} cr',
                    style: AymaType.mono(size: 12, color: ac.fgDim)),
              ],
            ),
          ),
      const SizedBox(height: 24),
      Text(
        'Credits cover every call your activity drives — Ayma’s '
        'text and voice replies, icebreakers, and match scoring.',
        style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
      ),
    ];
  }

  List<Widget> _realMoneyChildren(BuildContext context, UsageSummary u) {
    final ac = context.ac;
    final groups = u.spendGroups;
    final resetAt = u.realMoneyResetAt?.toLocal();
    return [
      FilledButton.icon(
        key: const ValueKey('dev-free-reload'),
        onPressed: _reloading ? null : _reload,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Free reload'),
      ),
      const SizedBox(height: 20),
      // Big figure: what's been spent since the user last hit Reset (never
      // reset -> since tracking began, the same number as all time).
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(_usd(u.realMoneyUsd),
              style: AymaType.serif(size: 44, color: ac.fg)),
          Text('  spent for real',
              style: AymaType.sans(size: 15, color: ac.fgMute)),
        ],
      ),
      const SizedBox(height: 6),
      // Sub-line + the quiet Reset utility — deliberately not a big CTA.
      Row(
        children: [
          Expanded(
            child: Text(
              resetAt != null
                  ? 'Since your reset on ${_date(resetAt)}.'
                  : 'Since money tracking began — everyone starts at \$0.00.',
              style: AymaType.sans(size: 12, color: ac.fgMute),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey('reset-money-tracker'),
            onPressed: _resettingMoney ? null : _resetMoneyTracker,
            style: TextButton.styleFrom(
              foregroundColor: ac.fgMute,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.restart_alt_rounded, size: 15),
            label: Text('Reset',
                style: AymaType.sans(size: 12, color: ac.fgMute)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      // The smaller all-time figure — resets never touch it.
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(_usd(u.realMoneyAllTimeUsd),
              style: AymaType.serif(size: 20, color: ac.fgDim)),
          Text('  all time',
              style: AymaType.sans(size: 12, color: ac.fgMute)),
        ],
      ),
      const SizedBox(height: 24),
      const Eyebrow('Per conversation'),
      const SizedBox(height: 10),
      if (groups.isEmpty)
        Text('Nothing spent yet.',
            style: AymaType.sans(size: 14, soft: true, color: ac.fgMute))
      else
        for (final g in groups)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_groupTitle(g),
                          style: AymaType.sans(size: 14, color: ac.fg)),
                      const SizedBox(height: 2),
                      Text(_when(g),
                          style:
                              AymaType.sans(size: 11, color: ac.fgMute)),
                    ],
                  ),
                ),
                Text(_usd(g.costUsd),
                    style: AymaType.mono(size: 12, color: ac.fgDim)),
              ],
            ),
          ),
      const SizedBox(height: 24),
      Text(
        'These are Google’s published API rates billed to the project for '
        'the calls behind each conversation — the tokens are not free.',
        style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
      ),
    ];
  }
}

/// The Credits / Dev view segmented switch — same pill treatment as the
/// story editor's view switcher, kept local since the two screens shouldn't
/// couple.
class _SpendTabBar extends StatelessWidget {
  const _SpendTabBar({required this.view, required this.onChanged});
  final String view;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget seg(String value, String label) {
      final on = view == value;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('spend-tab-$value'),
          onTap: () => onChanged(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: on ? ac.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AymaType.sans(
                size: 12.5,
                weight: FontWeight.w600,
                color: on ? ac.onAccent : ac.fgDim,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Row(children: [
        seg('credits', 'Credits'),
        seg('dev', 'Dev view'),
      ]),
    );
  }
}
