import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/push_service.dart';
import '../theme.dart';
import '../widgets/notification_bell.dart';
import 'photo_management_screen.dart';
import 'private_wiki_screen.dart';
import 'profile_settings_screen.dart';
import 'public_wiki_screen.dart';
import 'splash_screen.dart';
import 'voice_preference_screen.dart';

/// Profile tab (§11.3, §14.3): a hub linking to the public profile, the private
/// wiki narrative, the structured-field editor, and account actions.
class ProfileTabScreen extends StatelessWidget {
  const ProfileTabScreen({super.key, this.auth});

  static const path = '/profile';

  final FirebaseAuth? auth;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: const [NotificationBellButton()],
      ),
      body: ListView(
        children: [
          _Item(
            icon: Icons.person_outline,
            label: 'Public profile',
            hint: 'What matches see',
            onTap: () => context.push(PublicWikiScreen.path),
          ),
          _Item(
            icon: Icons.auto_stories_outlined,
            label: 'Your private wiki',
            hint: "Ayma's understanding of you",
            onTap: () => context.push(PrivateWikiScreen.path),
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
            icon: Icons.record_voice_over_outlined,
            label: 'Ayma’s voice',
            hint: 'Pick the voice she speaks with',
            onTap: () => context.push(VoicePreferenceScreen.path),
          ),
          Divider(height: 1, color: ac.lineSoft),
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
      leading: Icon(icon, color: ac.fg),
      title: Text(label, style: AymaType.sans(size: 15, color: ac.fg)),
      subtitle: hint == null
          ? null
          : Text(hint!,
              style:
                  AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
      trailing: Icon(Icons.chevron_right, color: ac.fgMute),
      onTap: onTap,
    );
  }
}
