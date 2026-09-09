import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../screens/chat_screen.dart';
import '../screens/deep_dive_report_screen.dart';
import '../screens/dm_thread_screen.dart';
import '../screens/feedback_screen.dart';
import '../screens/explore_screen.dart';
import '../screens/main_shell_screen.dart';
import '../screens/match_report_screen.dart';
import '../screens/matches_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/notification_prefs_screen.dart';
import '../screens/photo_management_screen.dart';
import '../screens/preboarding_flow_screen.dart';
import '../screens/privacy_screen.dart';
import '../screens/story_editor_screen.dart';
import '../screens/wiki_notes_screen.dart';
import '../screens/profile_settings_screen.dart';
import '../screens/public_profile_screen.dart';
import '../screens/recovery_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/skills_screen.dart';
import '../screens/usage_screen.dart';
import '../screens/voice_preference_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/terms_screen.dart';

/// App router. Splash calls `POST /bootstrap` and routes on the server-derived
/// `session_mode` (§11.2 / `entryRouteFor`); the deep-link routes from §11.5
/// map 1:1 to notification `deep_link` strings.
final appRouter = GoRouter(
  initialLocation: SplashScreen.path,
  // Sign-in gate (§3.3): unauthenticated users can only reach the sign-in,
  // splash, terms and recovery screens; everything else bounces to sign-in.
  redirect: (context, state) {
    final user = FirebaseAuth.instance.currentUser;
    final signedIn = user != null && !user.isAnonymous;
    final loc = state.matchedLocation;
    const open = {
      SignInScreen.path,
      SplashScreen.path,
      TermsScreen.path,
      PrivacyScreen.path,
      RecoveryScreen.path,
    };
    if (!signedIn && !open.contains(loc)) return SignInScreen.path;
    if (signedIn && loc == SignInScreen.path) return SplashScreen.path;
    return null;
  },
  routes: [
    GoRoute(
      path: SplashScreen.path,
      builder: (context, state) => SplashScreen(apiClient: ApiClient()),
    ),
    GoRoute(
      path: SignInScreen.path,
      builder: (context, state) => const SignInScreen(),
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
      // Reached from splash for `marketing` mode (§3.3) — the pre-signup,
      // "Get started" chat. The in-shell Ayma tab is a separate instance.
      path: ChatScreen.path,
      builder: (context, state) => const ChatScreen(marketing: true),
    ),
    GoRoute(
      path: ProfileSettingsScreen.path,
      builder: (context, state) => const ProfileSettingsScreen(),
    ),
    GoRoute(
      path: StoryEditorScreen.path,
      builder: (context, state) => const StoryEditorScreen(),
    ),
    GoRoute(
      path: WikiNotesScreen.path,
      builder: (context, state) => const WikiNotesScreen(),
    ),
    GoRoute(
      path: '/dm/:threadId',
      builder: (context, state) => DmThreadScreen(
        threadId: state.pathParameters['threadId']!,
      ),
    ),
    GoRoute(
      path: '/match/:matchId',
      builder: (context, state) => MatchReportScreen(
        matchId: state.pathParameters['matchId']!,
      ),
    ),
    GoRoute(
      path: DeepDiveReportScreen.path,
      builder: (context, state) => DeepDiveReportScreen(
        reportId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: PublicProfileScreen.path,
      builder: (context, state) => PublicProfileScreen(
        uid: state.pathParameters['uid']!,
      ),
    ),
    GoRoute(
      path: ExploreScreen.path,
      builder: (context, state) => ExploreScreen(
        initialQuery: state.uri.queryParameters['q'] ?? '',
      ),
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
      path: UsageScreen.path,
      builder: (context, state) => const UsageScreen(),
    ),
    GoRoute(
      path: FeedbackScreen.path,
      builder: (context, state) => const FeedbackScreen(),
    ),
    GoRoute(
      path: SettingsScreen.path,
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: SkillsScreen.path,
      builder: (context, state) => const SkillsScreen(),
    ),
    GoRoute(
      path: RecoveryScreen.path,
      builder: (context, state) => const RecoveryScreen(),
    ),
    GoRoute(
      path: TermsScreen.path,
      builder: (context, state) => const TermsScreen(),
    ),
    GoRoute(
      path: PrivacyScreen.path,
      builder: (context, state) => const PrivacyScreen(),
    ),
  ],
);
