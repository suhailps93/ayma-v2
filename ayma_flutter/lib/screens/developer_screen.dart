import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../build_info.dart';
import '../services/api_client.dart';
import '../services/ayma_session.dart';
import '../services/credits_balance.dart';
import '../services/dev_panel_flag.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import 'plan_screen.dart';

/// The hidden Developer panel, opened by tapping the build stamp in User
/// settings seven times (or long-pressing it). Its tools show only while the
/// `dev_panel` feature flag is on; the flag switch itself is always here, so
/// it can be turned back on. Dollar figures still come only for accounts on
/// the server's dev-view allowlist — the server withholds them otherwise.
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key, this.api, this.flag, this.auth});

  static const path = '/settings/developer';

  final ApiClient? api;
  final DevPanelFlag? flag;
  final FirebaseAuth? auth;

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  DevPanelFlag get _flag => widget.flag ?? DevPanelFlag.instance;
  final _password = TextEditingController();
  late Future<UsageSummary> _usage = _api.usage();
  bool _switching = false;
  bool _reloading = false;
  bool _resettingMoney = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _say(String msg, {AymaToastKind kind = AymaToastKind.info}) {
    if (!mounted) return;
    AymaToast.show(context, msg, kind: kind);
  }

  Future<void> _setFlag(bool value) async {
    if (_switching) return;
    final password = _password.text;
    if (password.isEmpty) {
      _say('Enter the developer password first.', kind: AymaToastKind.warning);
      return;
    }
    setState(() => _switching = true);
    try {
      final now = await _api.setDevPanelFlag(
        password: password,
        enabled: value,
      );
      _flag.enabled.value = now;
      _password.clear();
      _say(now ? 'Developer panel is on.' : 'Developer panel is off.',
          kind: AymaToastKind.success);
    } on ApiException catch (e) {
      _say(switch (e.statusCode) {
        403 => 'Wrong password.',
        429 => 'Too many wrong passwords. Try again later.',
        503 => 'Switching is not configured on the server.',
        _ => "Couldn't switch the flag. Check your connection.",
      }, kind: AymaToastKind.error);
    } catch (_) {
      _say("Couldn't switch the flag. Check your connection.",
          kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _reload() async {
    if (_reloading) return;
    setState(() => _reloading = true);
    try {
      final updated = await _api.topUpCredits();
      if (!mounted) return;
      CreditsBalance.instance.remaining.value = updated.creditsRemaining;
      setState(() {
        _usage = Future.value(updated);
      });
      // Clears a stale "Out of credits" voice banner and any capped chat
      // prompts left over from before this top-up.
      AymaSession.instance.voice.clearCappedError();
      AymaSession.instance.store.clearCappedTurns();
      _say('Credits reloaded — ${updated.creditsRemaining} left.',
          kind: AymaToastKind.success);
    } on UpgradeRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _reloading = false);
      await _showUpgrade(e.message);
    } catch (e) {
      _say("Couldn't reload credits ($e).", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  Future<void> _showUpgrade(String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        key: const ValueKey('upgrade-dialog'),
        title: const Text('Upgrade for more credits'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push(PlanScreen.path);
            },
            child: const Text('See plans'),
          ),
        ],
      ),
    );
  }

  /// Confirm → `POST /usage/reset-real-money`. The tracker restarts at $0.00;
  /// all time and the conversation history keep counting.
  Future<void> _resetMoneyTracker() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Reset the money tracker?'),
        content: const Text(
          'The tracker goes back to \$0.00 from now. All time keeps '
          'counting, and past conversations stay listed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
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
        _usage = Future.value(updated);
      });
      _say('Money tracker reset to \$0.00.', kind: AymaToastKind.success);
    } catch (e) {
      _say("Couldn't reset the money tracker ($e).", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _resettingMoney = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Developer'),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: _flag.enabled,
        builder: (context, on, _) => ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          children: [
            const Eyebrow('Feature flag'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Developer panel',
                        style: AymaType.sans(size: 15, color: ac.fg),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'dev_panel — this panel and dev-facing AI notes, '
                        'for everyone.',
                        style: AymaType.sans(
                          size: 12,
                          soft: true,
                          color: ac.fgMute,
                        ),
                      ),
                    ],
                  ),
                ),
                _switching
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Switch(
                        key: const ValueKey('dev-panel-switch'),
                        value: on,
                        onChanged: _setFlag,
                      ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('dev-password'),
              controller: _password,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Developer password',
              ),
            ),
            if (on) ...[
              const SizedBox(height: 36),
              const Eyebrow('Build'),
              const SizedBox(height: 12),
              _kv(context, 'Build', appBuildTag),
              _kv(
                context,
                'Mode',
                kReleaseMode
                    ? 'release'
                    : kProfileMode
                    ? 'profile'
                    : 'debug',
              ),
              _kv(
                context,
                'Account',
                (widget.auth ?? FirebaseAuth.instance).currentUser?.uid ?? '—',
              ),
              const SizedBox(height: 36),
              FutureBuilder<UsageSummary>(
                future: _usage,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text(
                      "Couldn't load spend (${snap.error}).",
                      style: AymaType.sans(size: 13, color: ac.error),
                    );
                  }
                  final u = snap.data;
                  if (u == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!u.isDev) {
                    return Text(
                      'Real-money spend is only sent to accounts on the '
                      "server's dev-view allowlist.",
                      key: const ValueKey('dev-spend-unavailable'),
                      style: AymaType.sans(
                        size: 13,
                        soft: true,
                        color: ac.fgMute,
                      ),
                    );
                  }
                  return _Spend(
                    usage: u,
                    reloading: _reloading,
                    resetting: _resettingMoney,
                    onReload: _reload,
                    onReset: _resetMoneyTracker,
                  );
                },
              ),
            ] else ...[
              const SizedBox(height: 24),
              Text(
                'The developer tools are hidden while dev_panel is off.',
                key: const ValueKey('dev-tools-hidden'),
                style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(k, style: AymaType.sans(size: 13, color: ac.fgMute)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: AymaType.mono(
                size: 12,
                color: ac.fg,
              ).copyWith(letterSpacing: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the account's usage really cost in dollars, per conversation, plus
/// the free reload — the former Credits screen "Dev view".
class _Spend extends StatelessWidget {
  const _Spend({
    required this.usage,
    required this.reloading,
    required this.resetting,
    required this.onReload,
    required this.onReset,
  });

  final UsageSummary usage;
  final bool reloading;
  final bool resetting;
  final VoidCallback onReload;
  final VoidCallback onReset;

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

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Dollars to the cent, with sub-cent precision below $0.10.
  static String _usd(double v) => v > 0 && v < 0.10
      ? '\$${v.toStringAsFixed(4)}'
      : '\$${v.toStringAsFixed(2)}';

  static String _date(DateTime t) => '${_months[t.month - 1]} ${t.day}';

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
    final ac = context.ac;
    final u = usage;
    final groups = u.spendGroups;
    final resetAt = u.realMoneyResetAt?.toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Eyebrow('Real money'),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              _usd(u.realMoneyUsd),
              style: AymaType.serif(size: 44, color: ac.fg),
            ),
            Flexible(
              child: Text(
                '  spent for real',
                style: AymaType.sans(size: 15, color: ac.fgMute),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                resetAt != null
                    ? 'Since your reset on ${_date(resetAt)}.'
                    : 'Since money tracking began — everyone starts at '
                          '\$0.00.',
                style: AymaType.sans(size: 12, color: ac.fgMute),
              ),
            ),
            TextButton(
              key: const ValueKey('reset-money-tracker'),
              onPressed: resetting ? null : onReset,
              child: const Text('Reset'),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              _usd(u.realMoneyAllTimeUsd),
              style: AymaType.serif(size: 20, color: ac.fgDim),
            ),
            Text('  all time', style: AymaType.sans(size: 12, color: ac.fgMute)),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          key: const ValueKey('dev-free-reload'),
          onPressed: reloading ? null : onReload,
          child: const Text('Free reload'),
        ),
        const SizedBox(height: 28),
        const Eyebrow('Per conversation'),
        const SizedBox(height: 8),
        if (groups.isEmpty)
          Text(
            'Nothing spent yet.',
            style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
          )
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
                        Text(
                          _groupTitle(g),
                          style: AymaType.sans(size: 14, color: ac.fg),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _when(g),
                          style: AymaType.sans(size: 11, color: ac.fgMute),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _usd(g.costUsd),
                    style: AymaType.mono(size: 12, color: ac.fgDim),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 20),
        Text(
          'These are Google’s published API rates billed to the project for '
          'the calls behind each conversation — the tokens are not free.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
      ],
    );
  }
}
