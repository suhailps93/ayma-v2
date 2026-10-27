import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../build_info.dart';
import '../services/api_client.dart';
import '../services/ayma_session.dart';
import '../services/credits_balance.dart';
import '../services/dev_panel_flag.dart';
import '../services/dev_panel_session.dart';
import '../services/feature_tour_store.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import 'admin_feedback_screen.dart';
import 'plan_screen.dart';
import 'release_notes_screen.dart';

/// The hidden Developer panel, opened by tapping the version row in User
/// settings seven times (or long-pressing it). Opening it shows ONLY a
/// password field: all contents — build / mode / account diagnostics,
/// real-money spend, the free reload, per-conversation cost, the detailed
/// release notes and the AI-notes flag toggle — stay hidden until the
/// developer password is verified server-side (`POST /dev/verify`). The unlock
/// lives only in memory for the app session ([DevPanelSession]); a restart, or
/// a long enough backgrounding, re-locks it. Dollar figures still come only
/// for accounts on the server's dev-view allowlist — the server withholds them
/// otherwise.
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({
    super.key,
    this.api,
    this.flag,
    this.session,
    this.auth,
  });

  static const path = '/settings/developer';

  final ApiClient? api;
  final DevPanelFlag? flag;
  final DevPanelSession? session;
  final FirebaseAuth? auth;

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  DevPanelFlag get _flag => widget.flag ?? DevPanelFlag.instance;
  DevPanelSession get _session => widget.session ?? DevPanelSession.instance;
  final _password = TextEditingController();
  late Future<UsageSummary> _usage = _api.usage();
  bool _unlocking = false;
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

  /// Verify the password server-side and, on success, unlock the panel's
  /// contents for this app session.
  Future<void> _unlock() async {
    if (_unlocking) return;
    final password = _password.text;
    if (password.isEmpty) {
      _say('Enter the developer password.', kind: AymaToastKind.warning);
      return;
    }
    setState(() => _unlocking = true);
    try {
      await _api.verifyDevPassword(password);
      _session.unlock(password);
      _password.clear();
    } on ApiException catch (e) {
      _say(switch (e.statusCode) {
        403 => 'Wrong password.',
        429 => 'Too many wrong passwords. Try again later.',
        503 => 'Developer access is not configured on the server.',
        _ => "Couldn't verify the password. Check your connection.",
      }, kind: AymaToastKind.error);
    } catch (_) {
      _say("Couldn't verify the password. Check your connection.",
          kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  /// Flip the `dev_panel` AI-notes flag, reusing the password verified at
  /// unlock — the toggle only ever shows while the session is unlocked.
  Future<void> _setFlag(bool value) async {
    if (_switching) return;
    final password = _session.password;
    if (password == null) return;
    setState(() => _switching = true);
    try {
      final now = await _api.setDevPanelFlag(
        password: password,
        enabled: value,
      );
      // Always reflect the server's confirmed (persisted) value — never the
      // requested one. If the write didn't take (server answered 200 but the
      // flag is unchanged), the switch stays where it truly is and we say so,
      // rather than showing a success toast for a change that never landed.
      _flag.enabled.value = now;
      if (now == value) {
        _say(now ? 'AI debug notes are on.' : 'AI debug notes are off.',
            kind: AymaToastKind.success);
      } else {
        _say(
            "Couldn't save that — the server kept AI notes "
            '${now ? 'on' : 'off'}. Try again.',
            kind: AymaToastKind.error);
      }
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        // The password changed under us (or the session is stale) — relock.
        _session.lock();
        _say('Developer access expired. Enter the password again.',
            kind: AymaToastKind.warning);
      } else {
        _say(switch (e.statusCode) {
          429 => 'Too many attempts. Try again later.',
          503 => 'Switching is not configured on the server.',
          _ => "Couldn't switch the flag. Check your connection.",
        }, kind: AymaToastKind.error);
      }
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
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Developer'),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: _session.unlocked,
        builder: (context, unlocked, _) => ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          children: unlocked ? _unlockedChildren(context) : _lockedChildren(context),
        ),
      ),
    );
  }

  /// Locked: only the password field and an unlock button — nothing sensitive.
  List<Widget> _lockedChildren(BuildContext context) {
    final ac = context.ac;
    return [
      const Eyebrow('Developer'),
      const SizedBox(height: 12),
      Text(
        'Enter the developer password to continue.',
        key: const ValueKey('dev-locked'),
        style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('dev-password'),
        controller: _password,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        onSubmitted: (_) => _unlock(),
        decoration: const InputDecoration(
          labelText: 'Developer password',
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('dev-unlock'),
        onPressed: _unlocking ? null : _unlock,
        child: _unlocking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Unlock'),
      ),
    ];
  }

  /// Unlocked: the AI-notes toggle, build diagnostics, real-money spend and the
  /// detailed release notes.
  List<Widget> _unlockedChildren(BuildContext context) {
    final ac = context.ac;
    return [
      const Eyebrow('AI debug notes'),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Show AI notes',
                  style: AymaType.sans(size: 15, color: ac.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  'dev_panel — dev-facing AI annotations (tags, confidence) '
                  'in the normal UI, for everyone.',
                  style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
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
              : ValueListenableBuilder<bool>(
                  valueListenable: _flag.enabled,
                  builder: (context, on, _) => Switch(
                    key: const ValueKey('dev-panel-switch'),
                    value: on,
                    onChanged: _setFlag,
                  ),
                ),
        ],
      ),
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
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
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
      const SizedBox(height: 36),
      const Eyebrow('Feedback'),
      const SizedBox(height: 8),
      ListTile(
        key: const ValueKey('dev-feedback-triage'),
        contentPadding: EdgeInsets.zero,
        title: Text('Triage feedback',
            style: AymaType.sans(size: 15, color: ac.fg)),
        subtitle: Text('Bugs and feature requests from chat and Settings.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        trailing: Icon(Icons.chevron_right, color: ac.fgMute),
        onTap: () => context.push(AdminFeedbackScreen.path),
      ),
      const SizedBox(height: 36),
      const Eyebrow('Release notes'),
      const SizedBox(height: 8),
      ListTile(
        key: const ValueKey('dev-release-notes'),
        contentPadding: EdgeInsets.zero,
        title: Text("What's new",
            style: AymaType.sans(size: 15, color: ac.fg)),
        subtitle: Text('The full changelog, newest first.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        trailing: Icon(Icons.chevron_right, color: ac.fgMute),
        onTap: () => context.push(ReleaseNotesScreen.path),
      ),
      const SizedBox(height: 36),
      const Eyebrow('Feature tour'),
      const SizedBox(height: 8),
      ListTile(
        key: const ValueKey('dev-reset-feature-tour'),
        contentPadding: EdgeInsets.zero,
        title: Text('Reset feature tour',
            style: AymaType.sans(size: 15, color: ac.fg)),
        subtitle: Text('Show the first-launch walkthrough again next launch.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        trailing: Icon(Icons.refresh, color: ac.fgMute),
        onTap: () async {
          await featureTourStoreGlobal.reset();
          _say('Feature tour will show on next launch.',
              kind: AymaToastKind.success);
        },
      ),
    ];
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
    'dm_assist': 'DM coaching',
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
