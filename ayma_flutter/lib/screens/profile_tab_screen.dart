import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/push_service.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/notification_bell.dart';
import '../widgets/staggered.dart';
import 'explore_preview_screen.dart';
import 'photo_management_screen.dart';
import 'private_wiki_screen.dart';
import 'profile_settings_screen.dart';
import 'public_wiki_screen.dart';
import 'settings_screen.dart';
import 'usage_screen.dart';
import 'splash_screen.dart';
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
    final groups = <({String label, List<Widget> rows})>[
      (
        label: 'Profile',
        rows: [
          _Item(
            icon: Icons.person_outline,
            label: 'Public profile',
            hint: 'What matches see',
            onTap: () => context.push(PublicWikiScreen.path),
          ),
          _Item(
            icon: Icons.travel_explore_outlined,
            label: 'Preview on Explore',
            hint: 'How others see your card',
            onTap: () => context.push(ExplorePreviewScreen.path),
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
        ],
      ),
      (
        label: 'Your story',
        rows: [
          _Item(
            icon: Icons.auto_stories_outlined,
            label: 'Your private wiki',
            hint: "Ayma's understanding of you",
            onTap: () => context.push(PrivateWikiScreen.path),
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
            icon: Icons.data_usage,
            label: 'Usage',
            hint: 'Tokens used vs. your limit',
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
            icon: Icons.logout,
            label: 'Sign out',
            onTap: () async {
              await PushService().clearToken();
              await (auth ?? FirebaseAuth.instance).signOut();
              if (context.mounted) context.go(SplashScreen.path);
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
  });

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;

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
      trailing: Icon(Icons.chevron_right, color: ac.fgMute, size: 18),
      onTap: onTap,
    );
  }
}
