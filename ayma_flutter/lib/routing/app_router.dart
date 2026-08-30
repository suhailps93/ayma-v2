import 'package:go_router/go_router.dart';

import '../screens/admin_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/credential_picker_screen.dart';
import '../screens/dm_thread_screen.dart';
import '../screens/explore_screen.dart';
import '../screens/main_shell_screen.dart';
import '../screens/matches_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/notification_prefs_screen.dart';
import '../screens/photo_management_screen.dart';
import '../screens/preboarding_flow_screen.dart';
import '../screens/private_wiki_screen.dart';
import '../screens/profile_settings_screen.dart';
import '../screens/public_wiki_screen.dart';
import '../screens/recovery_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/voice_preference_screen.dart';
import '../screens/splash_screen.dart';

/// App router (skeleton).
///
/// Placeholder routes — splash, preboarding, main shell — plus the credential
/// picker (Step 5). No `session_mode` redirect logic yet (§11.2 / Step 34); the
/// deep-link routes from §11.5 are added in later phases.
final appRouter = GoRouter(
  initialLocation: SplashScreen.path,
  routes: [
    GoRoute(
      path: SplashScreen.path,
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: PreboardingFlowScreen.path,
      builder: (context, state) => const PreboardingFlowScreen(),
    ),
    GoRoute(
      path: MainShellScreen.path,
      builder: (context, state) => const MainShellScreen(),
    ),
    GoRoute(
      path: ChatScreen.path,
      builder: (context, state) => const ChatScreen(),
    ),
    GoRoute(
      path: ProfileSettingsScreen.path,
      builder: (context, state) => const ProfileSettingsScreen(),
    ),
    GoRoute(
      path: PrivateWikiScreen.path,
      builder: (context, state) => const PrivateWikiScreen(),
    ),
    GoRoute(
      path: '/dm/:threadId',
      builder: (context, state) => DmThreadScreen(
        threadId: state.pathParameters['threadId']!,
      ),
    ),
    GoRoute(
      path: ExploreScreen.path,
      builder: (context, state) => const ExploreScreen(),
    ),
    GoRoute(
      path: MatchesScreen.path,
      builder: (context, state) => const MatchesScreen(),
    ),
    GoRoute(
      path: NotificationCenterScreen.path,
      builder: (context, state) => const NotificationCenterScreen(),
    ),
    GoRoute(
      path: NotificationPrefsScreen.path,
      builder: (context, state) => const NotificationPrefsScreen(),
    ),
    GoRoute(
      path: PhotoManagementScreen.path,
      builder: (context, state) => const PhotoManagementScreen(),
    ),
    GoRoute(
      path: VoicePreferenceScreen.path,
      builder: (context, state) => const VoicePreferenceScreen(),
    ),
    GoRoute(
      path: AdminScreen.path,
      builder: (context, state) => const AdminScreen(),
    ),
    GoRoute(
      path: SettingsScreen.path,
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: PublicWikiScreen.path,
      builder: (context, state) => const PublicWikiScreen(),
    ),
    GoRoute(
      path: RecoveryScreen.path,
      builder: (context, state) => const RecoveryScreen(),
    ),
    GoRoute(
      path: CredentialPickerScreen.path,
      builder: (context, state) => const CredentialPickerScreen(),
      routes: [
        GoRoute(
          path: 'phone',
          builder: (context, state) => buildPhoneLinkScreen(state.extra),
        ),
      ],
    ),
  ],
);
