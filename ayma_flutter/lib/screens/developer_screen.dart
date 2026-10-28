import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../build_info.dart';
import '../services/api_client.dart';
import '../services/ayma_session.dart';
import '../services/credits_balance.dart';
import '../services/dev_panel_session.dart';
import '../services/feature_tour_store.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import 'admin_feedback_screen.dart';
import 'feature_tour_screen.dart';
import 'plan_screen.dart';
import 'release_notes_screen.dart';
import 'story_editor_screen.dart';

/// The hidden Developer panel, opened by tapping the version row in User
/// settings seven times (or long-pressing it). Opening it shows ONLY a
/// password field: all contents — build / mode / account diagnostics,
/// real-money spend, the free reload, per-conversation cost, the detailed
/// release notes and the dev-only Ayma's-notes entry — stay hidden until the
/// developer password is verified server-side (`POST /dev/verify`). The unlock
/// lives only in memory for the app session ([DevPanelSession]); a restart, or
/// a long enough backgrounding, re-locks it. Dollar figures still come only
/// for accounts on the server's dev-view allowlist — the server withholds them
/// otherwise.
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({
    super.key,
    this.api,
    this.session,
    this.auth,
  });

  static const path = '/settings/developer';

  final ApiClient? api;
  final DevPanelSession? session;
  final FirebaseAuth? auth;

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  DevPanelSession get _session => widget.session ?? DevPanelSession.instance;
  final _password = TextEditingController();
  late Future<UsageSummary> _usage = _api.usage();
  bool _unlocking = false;
  bool _reloading = false;
  bool _resettingMoney = false;

  /// Dual-cloud voice agent toggle: which cloud serves the next voice call
  /// (`cloudrun` | `livekit`). Null until loaded; `_voiceCloudBusy` while a
  /// read or write is in flight.
  String? _voiceCloud;
  bool _voiceCloudBusy = false;
  bool _voiceCloudLoaded = false;

  /// The plan whose dev test-upgrade is in flight (`plus`/`pro`/`max`), or null.
  String? _upgradingPlan;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// Load the saved voice-agent-cloud choice once the panel is unlocked.
  Future<void> _loadVoiceCloud() async {
    if (_voiceCloudLoaded || _voiceCloudBusy) return;
    setState(() => _voiceCloudBusy = true);
    try {
      final v = await _api.voiceAgentCloud();
      if (!mounted) return;
      setState(() {
        _voiceCloud = v;
        _voiceCloudLoaded = true;
      });
    } catch (_) {
      // Leave it unloaded; the row shows a retry affordance via the toggle.
    } finally {
      if (mounted) setState(() => _voiceCloudBusy = false);
    }
  }

  Future<void> _setVoiceCloud(String cloud) async {
    if (_voiceCloudBusy || _voiceCloud == cloud) return;
    setState(() => _voiceCloudBusy = true);
    try {
      final saved = await _api.setVoiceAgentCloud(cloud);
      if (!mounted) return;
      setState(() => _voiceCloud = saved);
      _say(
        saved == 'livekit'
            ? 'Voice agent: LiveKit Cloud (next call).'
            : 'Voice agent: Cloud Run (next call).',
        kind: AymaToastKind.success,
      );
    } catch (e) {
      _say("Couldn't switch voice agent cloud ($e).",
          kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _voiceCloudBusy = false);
    }
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

  /// DEV/TEST ONLY — simulate upgrading to [plan] (`plus`/`pro`/`max`) with no
  /// real payment. The server grants that tier's monthly credit pool through
  /// the same path a real entitlement uses; here we just refresh the balance
  /// and plan from the returned usage view. Gated the same way as the rest of
  /// this panel (dev unlock + the server's dev-view allowlist).
  Future<void> _testUpgrade(String plan) async {
    if (_upgradingPlan != null) return;
    setState(() => _upgradingPlan = plan);
    try {
      final updated = await _api.testUpgrade(plan);
      if (!mounted) return;
      CreditsBalance.instance.remaining.value = updated.creditsRemaining;
      setState(() {
        _usage = Future.value(updated);
      });
      AymaSession.instance.voice.clearCappedError();
      AymaSession.instance.store.clearCappedTurns();
      _say(
        'Test upgrade: ${updated.plan} plan — '
        '${updated.creditsRemaining} credits (no payment).',
        kind: AymaToastKind.success,
      );
    } on ApiException catch (e) {
      _say(
        e.statusCode == 403
            ? 'Test upgrade is for dev-view accounts only.'
            : "Couldn't apply the test upgrade (${e.statusCode}).",
        kind: AymaToastKind.error,
      );
    } catch (e) {
      _say("Couldn't apply the test upgrade ($e).", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _upgradingPlan = null);
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
        builder: (context, unlocked, _) {
          if (unlocked && !_voiceCloudLoaded && !_voiceCloudBusy) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadVoiceCloud();
            });
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            children:
                unlocked ? _unlockedChildren(context) : _lockedChildren(context),
          );
        },
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

  /// Unlocked: build diagnostics, real-money spend, the dev-only Ayma's-notes
  /// entry and the detailed release notes.
  List<Widget> _unlockedChildren(BuildContext context) {
    final ac = context.ac;
    return [
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
      ..._voiceCloudSection(context),
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
            upgradingPlan: _upgradingPlan,
            onTestUpgrade: _testUpgrade,
          );
        },
      ),
      const SizedBox(height: 36),
      const Eyebrow("Ayma's notes"),
      const SizedBox(height: 8),
      ListTile(
        key: const ValueKey('dev-ayma-notes'),
        contentPadding: EdgeInsets.zero,
        title: Text("Ayma's notes",
            style: AymaType.sans(size: 15, color: ac.fg)),
        subtitle: Text(
            'The intelligence beneath the portrait — observed, unconfirmed '
            'analysis. Dev-only.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        trailing: Icon(Icons.chevron_right, color: ac.fgMute),
        onTap: () => context.push(AymaNotesScreen.path),
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
        title: Text('Reset & preview feature tour',
            style: AymaType.sans(size: 15, color: ac.fg)),
        subtitle: Text('Opens the first-launch walkthrough now, and clears the '
            'seen flag so it also shows again on next launch.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        trailing: Icon(Icons.refresh, color: ac.fgMute),
        onTap: () async {
          // Dev-only preview: clear the flag (so reset + relaunch also works
          // for a signed-in dev via the relaxed splash gate) and jump straight
          // to the tour so it can be reviewed right here.
          await featureTourStoreGlobal.reset();
          if (!context.mounted) return;
          context.go(FeatureTourScreen.path);
        },
      ),
    ];
  }

  /// Dual-cloud voice agent toggle (ARCHITECTURE §1.1): switch which cloud
  /// serves the next voice call. `cloudrun` is the default and all of
  /// production; `livekit` opts this account into the LiveKit-Cloud-hosted
  /// agent. Wrap-based so it reflows (no fixed width) and the layout matrix
  /// stays green at large text scales / narrow widths.
  List<Widget> _voiceCloudSection(BuildContext context) {
    final ac = context.ac;
    final current = _voiceCloud;
    return [
      const Eyebrow('Voice agent cloud'),
      const SizedBox(height: 8),
      Text(
        'Which cloud serves your next voice call. Cloud Run is the default '
        '(production); LiveKit Cloud is the hosted-agent migration. Takes '
        'effect on the next call.',
        style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (id, label) in const [
            ('cloudrun', 'Cloud Run'),
            ('livekit', 'LiveKit Cloud'),
          ])
            ChoiceChip(
              key: ValueKey('dev-voice-cloud-$id'),
              label: Text(label),
              selected: current == id,
              onSelected: (_voiceCloudBusy || current == null)
                  ? null
                  : (_) => _setVoiceCloud(id),
            ),
        ],
      ),
      if (current == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _voiceCloudBusy ? 'Loading…' : 'Could not load current value.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ),
      const SizedBox(height: 36),
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
    required this.upgradingPlan,
    required this.onTestUpgrade,
  });

  final UsageSummary usage;
  final bool reloading;
  final bool resetting;
  final VoidCallback onReload;
  final VoidCallback onReset;

  /// The plan whose dev test-upgrade is in flight, or null; disables the row.
  final String? upgradingPlan;
  final ValueChanged<String> onTestUpgrade;

  /// The dev test-upgrade tiers (plan id -> button label).
  static const _testPlans = [
    ('plus', 'Plus'),
    ('pro', 'Pro'),
    ('max', 'Max'),
  ];

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
        // Wrap, not Row: at large text scales the big serif figure plus its
        // label can exceed the width, so the label reflows below instead of
        // overflowing (layout matrix: 1.5x/2.0x narrow sizes).
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            Text(
              _usd(u.realMoneyUsd),
              style: AymaType.serif(size: 44, color: ac.fg),
            ),
            Text(
              '  spent for real',
              style: AymaType.sans(size: 15, color: ac.fgMute),
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
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
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
        const Eyebrow('Test upgrade'),
        const SizedBox(height: 8),
        Text(
          'Simulate upgrading — no payment. Grants the plan’s monthly credit '
          'pool through the real grant path so you can check credits per tier.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (id, label) in _testPlans)
              OutlinedButton(
                key: ValueKey('dev-test-upgrade-$id'),
                onPressed: upgradingPlan != null ? null : () => onTestUpgrade(id),
                child: upgradingPlan == id
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(label),
              ),
          ],
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
