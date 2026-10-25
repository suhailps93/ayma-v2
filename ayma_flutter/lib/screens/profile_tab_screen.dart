import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/meta_integrations.dart';
import '../services/credits_balance.dart';
import '../services/push_service.dart';
import '../services/revenuecat_service.dart';
import '../services/subscription_status.dart';
import 'plans_screen.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/completeness_ring.dart';
import '../widgets/staggered.dart';
import 'ayma_settings_screen.dart';
import 'complete_profile_screen.dart';
import 'my_public_profile_screen.dart';
import 'story_editor_screen.dart';
import 'profile_settings_screen.dart';
import 'feedback_screen.dart';
import 'invite_friends_screen.dart';
import 'privacy_screen.dart';
import 'instagram_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'subscription_screen.dart';
import 'terms_screen.dart';
import 'usage_screen.dart';
import 'sign_in_screen.dart';

/// Profile tab (§11.3, §14.3): a hub linking to the "You" items (public
/// profile, story, details, web-research and Appearance reports, user
/// settings), the "Ayma" items (her settings, credits) and account actions — grouped
/// into eyebrow-headed cards in the Ayma design language.
class ProfileTabScreen extends StatelessWidget {
  const ProfileTabScreen({super.key, this.auth, this.apiClient});

  static const path = '/profile';

  final FirebaseAuth? auth;
  final ApiClient? apiClient;

  /// Opens the caller's last web-research report; with none yet, the Skills
  /// screen, which offers to run one. A failed lookup also lands there — it
  /// never strands the tap.
  Future<void> _openWebResearch(BuildContext context) async {
    var reportId = '';
    try {
      final mine = await (apiClient ?? ApiClient()).deepDiveMine();
      reportId = mine?.reportId ?? '';
    } catch (_) {
      /* fall through to the run screen */
    }
    if (!context.mounted) return;
    context.push(reportId.isEmpty
        ? SkillsScreen.path
        : '/deep-dive/${Uri.encodeComponent(reportId)}');
  }

  /// Same for the Appearance report — `/appearance/current` when one exists.
  Future<void> _openAppearance(BuildContext context) async {
    var hasReport = false;
    try {
      final rows = await (apiClient ?? ApiClient()).appearanceHistory();
      hasReport = rows.isNotEmpty;
    } catch (_) {
      /* fall through to the run screen */
    }
    if (!context.mounted) return;
    context.push(hasReport ? '/appearance/current' : SkillsScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <({String label, List<Widget> rows})>[
      (
        label: 'You',
        rows: [
          _Item(
            icon: Icons.person_outline,
            label: 'My public profile',
            hint: 'Exactly what others see when they open your profile',
            onTap: () => context.push(MyPublicProfileScreen.path),
          ),
          _Item(
            icon: Icons.auto_stories_outlined,
            label: 'My story',
            hint: 'Everything, what\'s public, and Ayma\'s own AI notes — with '
                'version history',
            onTap: () => context.push(StoryEditorScreen.path),
          ),
          _Item(
            icon: Icons.tune,
            label: 'Profile details',
            hint: 'Name, birthdate, who you want to meet',
            onTap: () => context.push(ProfileSettingsScreen.path),
          ),
          _Item(
            icon: Icons.travel_explore,
            label: 'Search the web about me',
            hint: 'Your latest web-research report, or run a new one',
            onTap: () => _openWebResearch(context),
          ),
          _Item(
            icon: Icons.auto_awesome_outlined,
            label: 'Appearance',
            hint: 'Your latest appearance report, or run a new one',
            onTap: () => _openAppearance(context),
          ),
          _Item(
            icon: Icons.settings_outlined,
            label: 'User settings',
            hint: 'Theme, matching, verification',
            onTap: () => context.push(SettingsScreen.path),
          ),
          // Connect Google: built and working, deferred out of the visible UI
          // for v1. Connect Instagram: V2, shown only when the
          // `meta_integrations` flag is on (default off).
          if (MetaIntegrations.enabled.value)
            _Item(
              icon: Icons.camera_alt_outlined,
              label: 'Connect Instagram',
              hint: 'Import photos from your Instagram account',
              onTap: () => context.push(InstagramScreen.path),
            ),
        ],
      ),
      (
        label: 'Ayma',
        rows: [
          _Item(
            icon: Icons.record_voice_over_outlined,
            label: 'Ayma’s settings',
            hint: 'Her voice, animation, and what she remembers',
            onTap: () => context.push(AymaSettingsScreen.path),
          ),
          _Item(
            icon: Icons.toll_rounded,
            label: 'Credits',
            hint: 'Your balance and where it goes',
            trailingBefore: _CreditsBalance(apiClient: apiClient),
            onTap: () => context.push(UsageScreen.path),
          ),
          _SubscriptionRow(apiClient: apiClient),
        ],
      ),
      (
        label: 'Account',
        rows: [
          _Item(
            icon: Icons.person_add_alt_1_outlined,
            label: 'Invite friends',
            hint: 'Share your link — Ayma finds their person too',
            onTap: () => context.push(InviteFriendsScreen.path),
          ),
          _Item(
            icon: Icons.feedback_outlined,
            label: 'Send feedback',
            hint: 'Report a bug or suggest a feature',
            onTap: () => context.push(FeedbackScreen.path),
          ),
          _Item(
            icon: Icons.description_outlined,
            label: 'Terms of Service',
            hint: 'How Ayma uses your photos and public information',
            onTap: () => context.push(TermsScreen.path),
          ),
          _Item(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy Policy',
            hint: 'What we collect, why, and your choices',
            onTap: () => context.push(PrivacyScreen.path),
          ),
          _Item(
            icon: Icons.logout,
            label: 'Sign out',
            onTap: () async {
              await PushService().clearToken();
              await (auth ?? FirebaseAuth.instance).signOut();
              if (context.mounted) context.go(SignInScreen.path);
            },
          ),
        ],
      ),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const AymaScreenHeader(
              title: 'You',
              // Back arrow when pushed standalone (deep link / `open_screen`)
              // — invisible in the shell tab, where the route can't pop.
              automaticallyImplyBack: true,
            ),
            _CompletenessCard(apiClient: apiClient),
            for (var g = 0; g < groups.length; g++)
              FadeSlideIn(
                delay: staggerDelay(g, stepMs: 60),
                child: _Group(label: groups[g].label, rows: groups[g].rows),
              ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.rows});

  final String label;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 10),
            child: Eyebrow(label),
          ),
          Container(
            decoration: BoxDecoration(
              color: ac.bgElev,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ac.lineSoft, width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            // Transparent Material between this colored Container and the
            // ListTiles in `rows`: without it, ListTile's own
            // background/ink-splash paint (which lands on the nearest
            // Material ancestor) is hidden behind this Container's
            // BoxDecoration — Flutter now asserts on that in debug mode.
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) Divider(height: 0.5, color: ac.lineSoft),
                    rows[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.onTap,
    this.hint,
    this.trailingBefore,
  });

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;

  /// Optional widget shown just before the chevron (e.g. a live value).
  final Widget? trailingBefore;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ListTile(
      leading: Icon(icon, color: ac.fgDim, size: 20),
      title: Text(label, style: AymaType.sans(size: 15, color: ac.fg)),
      subtitle: hint == null
          ? null
          : Text(hint!,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingBefore != null) ...[
            trailingBefore!,
            const SizedBox(width: 8),
          ],
          Icon(Icons.chevron_right, color: ac.fgMute, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Profile "Subscription" row: shows the current plan; a free user's tap goes
/// straight to the plans, a subscriber's to the manage/cancel screen.
class _SubscriptionRow extends StatefulWidget {
  const _SubscriptionRow({this.apiClient});

  final ApiClient? apiClient;

  @override
  State<_SubscriptionRow> createState() => _SubscriptionRowState();
}

class _SubscriptionRowState extends State<_SubscriptionRow> {
  late Future<SubscriptionStatus> _status = _load();
  SubscriptionStatus _last = SubscriptionStatus.free;

  Future<SubscriptionStatus> _load() => SubscriptionStatus.load(
        RevenueCatService.instance,
        widget.apiClient ?? ApiClient(),
      );

  Future<void> _open() async {
    await context.push(
      _last.isSubscribed ? SubscriptionScreen.path : PlansScreen.path,
    );
    if (!mounted) return;
    setState(() {
      _status = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return FutureBuilder<SubscriptionStatus>(
      future: _status,
      builder: (context, snap) {
        _last = snap.data ?? _last;
        return _Item(
          icon: Icons.workspace_premium_outlined,
          label: 'Subscription',
          hint: 'Your plan, renewal and cancellation',
          trailingBefore: snap.hasData
              ? Text(
                  _last.planName,
                  key: const ValueKey('subscription-row-plan'),
                  style: AymaType.mono(size: 13, color: ac.fgDim),
                )
              : null,
          onTap: _open,
        );
      },
    );
  }
}

/// The live credit balance shown on the Profile "Credits" row. Fetches once;
/// renders nothing until it has a number (and stays silent on error).
class _CreditsBalance extends StatefulWidget {
  const _CreditsBalance({this.apiClient});

  final ApiClient? apiClient;

  @override
  State<_CreditsBalance> createState() => _CreditsBalanceState();
}

class _CreditsBalanceState extends State<_CreditsBalance> {
  @override
  void initState() {
    super.initState();
    // Kept alive with the rest of the tab shell, so this only ever runs
    // once per app session unless something else refreshes the shared
    // balance — which is exactly what CreditsBalance is for (see its doc).
    if (CreditsBalance.instance.remaining.value == null) _load();
  }

  Future<void> _load() async {
    try {
      final u = await (widget.apiClient ?? ApiClient()).usage();
      CreditsBalance.instance.remaining.value = u.creditsRemaining;
    } catch (_) {/* silent — the row still navigates to the full screen */}
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: CreditsBalance.instance.remaining,
      builder: (context, n, _) {
        if (n == null) return const SizedBox.shrink();
        return CreditPill(amount: n, dim: n == 0);
      },
    );
  }
}

/// The prominent "profile is N% complete" card at the top of the Profile tab.
/// Fetches once on build; a slim placeholder while loading; the whole card is
/// hidden on a fetch error (never a red box on the profile). Tapping opens the
/// "Complete your profile" screen.
class _CompletenessCard extends StatefulWidget {
  const _CompletenessCard({this.apiClient});

  final ApiClient? apiClient;

  @override
  State<_CompletenessCard> createState() => _CompletenessCardState();
}

class _CompletenessCardState extends State<_CompletenessCard> {
  Completeness? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await (widget.apiClient ?? ApiClient()).completeness();
      if (mounted) setState(() => _data = c);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final ac = context.ac;

    if (_data == null) {
      // Slim placeholder — reserves roughly the card's height, no error state.
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Container(
          height: 84,
          decoration: BoxDecoration(
            color: ac.bgElev,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ac.lineSoft, width: 0.5),
          ),
        ),
      );
    }

    final c = _data!;
    final done = c.isComplete;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Material(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(CompleteProfileScreen.path),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ac.lineSoft, width: 0.5),
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                CompletenessRing(
                  score: c.score, complete: c.isComplete, size: 56, stroke: 5,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        done
                            ? "You're all caught up ✓"
                            : 'Your profile is ${c.score}% complete',
                        style: AymaType.sans(
                            size: 15, weight: FontWeight.w600, color: ac.fg),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        done
                            ? 'Ayma keeps sharpening your matches as she learns.'
                            : 'Complete it for more accurate matches and a '
                                'better match pool.',
                        style: AymaType.sans(
                            size: 12, soft: true, color: ac.fgMute, height: 1.4),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: ac.fgMute, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
