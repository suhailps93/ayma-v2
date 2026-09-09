import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/push_service.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/notification_bell.dart';
import '../widgets/staggered.dart';
import 'photo_management_screen.dart';
import 'story_editor_screen.dart';
import 'wiki_notes_screen.dart';
import 'profile_settings_screen.dart';
import 'feedback_screen.dart';
import 'privacy_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'terms_screen.dart';
import 'usage_screen.dart';
import 'sign_in_screen.dart';
import 'voice_preference_screen.dart';

/// Profile tab (§11.3, §14.3): a hub linking to the public profile, the private
/// wiki narrative, the structured-field editor, and account actions — grouped
/// into eyebrow-headed cards in the Ayma design language.
class ProfileTabScreen extends StatelessWidget {
  const ProfileTabScreen({super.key, this.auth});

  static const path = '/profile';

  final FirebaseAuth? auth;

  @override
  Widget build(BuildContext context) {
    final myUid = (auth ?? FirebaseAuth.instance).currentUser?.uid ?? '';
    final groups = <({String label, List<Widget> rows})>[
      (
        label: 'Profile',
        rows: [
          _Item(
            icon: Icons.person_outline,
            label: 'My public profile',
            hint: 'Exactly what others see when they open your profile',
            onTap: myUid.isEmpty
                ? () {}
                : () => context.push('/profile/user/$myUid'),
          ),
          _Item(
            icon: Icons.photo_library_outlined,
            label: 'Photos',
            hint: 'Add, remove, reorder, connect Instagram',
            onTap: () => context.push(PhotoManagementScreen.path),
          ),
          _Item(
            icon: Icons.tune,
            label: 'Profile details',
            hint: 'Name, birthdate, who you want to meet',
            onTap: () => context.push(ProfileSettingsScreen.path),
          ),
          _Item(
            icon: Icons.auto_awesome,
            label: 'Skills',
            hint: 'Ayma can search the web about you, analyse a photo…',
            onTap: () => context.push(SkillsScreen.path),
          ),
        ],
      ),
      (
        label: 'Your story',
        rows: [
          _Item(
            icon: Icons.auto_stories_outlined,
            label: 'Your Story',
            hint: 'Edit your story and your public profile, with version history',
            onTap: () => context.push(StoryEditorScreen.path),
          ),
          _Item(
            icon: Icons.psychology_alt_outlined,
            label: 'AI notes (debug)',
            hint: 'The compiled notes Ayma reads about you — removed before launch',
            onTap: () => context.push(WikiNotesScreen.path),
          ),
        ],
      ),
      (
        label: 'Ayma',
        rows: [
          _Item(
            icon: Icons.record_voice_over_outlined,
            label: 'Ayma’s voice',
            hint: 'Pick the voice she speaks with',
            onTap: () => context.push(VoicePreferenceScreen.path),
          ),
          _Item(
            icon: Icons.toll_rounded,
            label: 'Credits',
            hint: 'Your balance and where it goes',
            trailingBefore: const _CreditsBalance(),
            onTap: () => context.push(UsageScreen.path),
          ),
        ],
      ),
      (
        label: 'Account',
        rows: [
          _Item(
            icon: Icons.settings_outlined,
            label: 'Settings',
            hint: 'Appearance',
            onTap: () => context.push(SettingsScreen.path),
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
              eyebrow: 'Your account',
              title: 'You',
              action: NotificationBellButton(),
            ),
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
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 0.5, color: ac.lineSoft),
                  rows[i],
                ],
              ],
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

/// The live credit balance shown on the Profile "Credits" row. Fetches once;
/// renders nothing until it has a number (and stays silent on error).
class _CreditsBalance extends StatefulWidget {
  const _CreditsBalance();

  @override
  State<_CreditsBalance> createState() => _CreditsBalanceState();
}

class _CreditsBalanceState extends State<_CreditsBalance> {
  int? _remaining;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final u = await ApiClient().usage();
      if (mounted) setState(() => _remaining = u.creditsRemaining);
    } catch (_) {/* silent — the row still navigates to the full screen */}
  }

  @override
  Widget build(BuildContext context) {
    final n = _remaining;
    if (n == null) return const SizedBox.shrink();
    return CreditPill(amount: n, dim: n == 0);
  }
}
