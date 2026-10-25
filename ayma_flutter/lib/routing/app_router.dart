import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/meta_integrations.dart';
import '../services/app_context.dart';
import '../screens/accent_color_screen.dart';
import '../screens/appearance_report_screen.dart';
import '../screens/ayma_settings_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/complete_profile_screen.dart';
import '../screens/deep_dive_report_screen.dart';
import '../screens/dm_thread_screen.dart';
import '../screens/feedback_screen.dart';
import '../screens/explore_screen.dart';
import '../screens/main_shell_screen.dart';
import '../screens/match_report_screen.dart';
import '../screens/matches_screen.dart';
import '../screens/messages_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/notification_prefs_screen.dart';
import '../screens/google_account_screen.dart';
import '../screens/instagram_screen.dart';
import '../screens/invite_friends_screen.dart';
import '../screens/my_public_profile_screen.dart';
import '../screens/physical_attributes_report_screen.dart';
import '../screens/preboarding_flow_screen.dart';
import '../screens/privacy_screen.dart';
import '../screens/profile_tab_screen.dart';
import '../screens/story_editor_screen.dart';
import '../screens/profile_settings_screen.dart';
import '../screens/public_profile_screen.dart';
import '../screens/recovery_screen.dart';
import '../screens/delete_account_screen.dart';
import '../screens/underage_screen.dart';
import '../screens/release_notes_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/shared_report_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/skills_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/trial_paywall_screen.dart';
import '../services/revenuecat_service.dart';
import '../screens/subscription_screen.dart';
import '../screens/usage_screen.dart';
import '../screens/voice_preference_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/terms_screen.dart';
import '../widgets/nav_bar_shell.dart';

/// App router. Splash calls `POST /bootstrap` and routes on the server-derived
/// `session_mode` (§11.2 / `entryRouteFor`); the deep-link routes from §11.5
/// map 1:1 to notification `deep_link` strings.
///
/// Persistent bottom nav bar (founder ask: literally every screen, no
/// exceptions): every route below is wrapped in [NavBarShell] except —
/// - [MainShellScreen] itself, which renders the identical-looking bar as its
///   own `bottomNavigationBar`, bound to its live tab state (wrapping it too
///   would double it up);
/// - the pre-auth screens the redirect gate below already lets an
///   unauthenticated user reach ([SplashScreen], [SignInScreen],
///   [TermsScreen], [PrivacyScreen], [RecoveryScreen]) — there is no signed-in
///   session yet for the bar's tabs to mean anything, and tapping one would
///   just bounce straight back here;
/// - the marketing [ChatScreen] route (`marketing: true`) — the pre-signup
///   "just talk to Ayma first" landing chat for a `session_mode: marketing`
///   user (see `entryRouteFor`), reached signed in but before the account
///   has any of the profile/match/message data the other three tabs need;
///   routing them into the real 4-tab shell from here would be premature.
///   [PreboardingFlowScreen] (the interview flow right after) *does* get the
///   bar — explicit founder call, with its own step layout adjusted to make
///   room (see that file's `_stepPadding`);
/// - [PublicProfileScreen], which renders [AymaTabBar] itself (a
///   `Stack`+`Align`, tuned together with its own action rail's clearance —
///   see its own doc) rather than through [NavBarShell].
final appRouter = GoRouter(
  initialLocation: SplashScreen.path,
  // Lets screens re-assert their voice screen-context when a child route pops.
  observers: [screenRouteObserver],
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
    // A shared-report link is public (the snapshot needs no auth).
    if (!signedIn && !open.contains(loc) && !loc.startsWith('/s/')) {
      return SignInScreen.path;
    }
    if (signedIn && loc == SignInScreen.path) return SplashScreen.path;
    return null;
  },
  routes: [
    GoRoute(
      path: SplashScreen.path,
      builder: (context, state) => SplashScreen(apiClient: ApiClient()),
    ),
    GoRoute(
      path: UnderageScreen.path,
      builder: (context, state) => const UnderageScreen(),
    ),
    GoRoute(
      path: SignInScreen.path,
      builder: (context, state) => const SignInScreen(),
    ),
    GoRoute(
      path: PreboardingFlowScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: PreboardingFlowScreen()),
    ),
    GoRoute(
      path: MainShellScreen.path,
      builder: (context, state) => const MainShellScreen(),
    ),
    GoRoute(
      // Reached from splash for `marketing` mode (§3.3) — the pre-signup,
      // "Get started" chat. The in-shell Ayma tab is a separate instance.
      // No nav bar (see the class doc above) — premature before preboarding.
      path: ChatScreen.path,
      builder: (context, state) => const ChatScreen(marketing: true),
    ),
    GoRoute(
      path: ProfileSettingsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: ProfileSettingsScreen()),
    ),
    GoRoute(
      path: CompleteProfileScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: CompleteProfileScreen()),
    ),
    GoRoute(
      path: StoryEditorScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: StoryEditorScreen()),
    ),
    GoRoute(
      path: '/dm/:threadId',
      builder: (context, state) => NavBarShell(
        child: DmThreadScreen(threadId: state.pathParameters['threadId']!),
      ),
    ),
    GoRoute(
      path: '/match/:matchId',
      builder: (context, state) => NavBarShell(
        child: MatchReportScreen(matchId: state.pathParameters['matchId']!),
      ),
    ),
    GoRoute(
      // A match request Ayma is waiting on a response to (§5.8, §14.3) —
      // the `match_request/{id}` notification deep link opens this directly.
      path: '/match-request/:matchId',
      builder: (context, state) => NavBarShell(
        child: MatchDetailScreen(matchId: state.pathParameters['matchId']!),
      ),
    ),
    GoRoute(
      path: DeepDiveReportScreen.path,
      builder: (context, state) => NavBarShell(
        child: DeepDiveReportScreen(reportId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: PhysicalAttributesReportScreen.path,
      builder: (context, state) => NavBarShell(
        child: PhysicalAttributesReportScreen(
          reportId: state.pathParameters['id']!,
        ),
      ),
    ),
    GoRoute(
      path: AppearanceReportScreen.path,
      builder: (context, state) => NavBarShell(
        child: AppearanceReportScreen(reportId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      // Not `NavBarShell`-wrapped like the routes around it: this screen
      // already renders `AymaTabBar` itself (a `Stack`+`Align`, not
      // `Scaffold.bottomNavigationBar` — see its own doc for why) — the
      // founder flagged this exact screen by name for the bar before this
      // wrapper existed, and it's tuned together with its own action rail's
      // clearance math (`AymaTabBar.contentHeight`). Wrapping it here too
      // would stack a second bar under/behind the first.
      path: PublicProfileScreen.path,
      builder: (context, state) =>
          PublicProfileScreen(uid: state.pathParameters['uid']!),
    ),
    GoRoute(
      path: ExploreScreen.path,
      builder: (context, state) => NavBarShell(
        child: ExploreScreen(
          initialQuery: state.uri.queryParameters['q'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: MatchesScreen.path,
      builder: (context, state) => const NavBarShell(child: MatchesScreen()),
    ),
    GoRoute(
      // Standalone pushes of these two shell tabs (e.g. Ayma's `open_screen`
      // voice tool) — the tab bar itself never routes here, it swaps the
      // shell's body in place instead. Mirrors `ExploreScreen`'s own
      // standalone route just above.
      path: MessagesScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: MessagesScreen()),
    ),
    GoRoute(
      path: ProfileTabScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: ProfileTabScreen()),
    ),
    GoRoute(
      path: NotificationCenterScreen.path,
      builder: (context, state) =>
          const NavBarShell(
            notificationsActive: true,
            child: NotificationCenterScreen(),
          ),
    ),
    GoRoute(
      path: NotificationPrefsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: NotificationPrefsScreen()),
    ),
    GoRoute(
      path: '/settings/photos',
      redirect: (context, state) => MyPublicProfileScreen.editPhotosPath,
    ),
    GoRoute(
      path: MyPublicProfileScreen.path,
      builder: (context, state) =>
          NavBarShell(
              child: MyPublicProfileScreen(
                  openPhotoEditor:
                      state.uri.queryParameters['edit'] == 'photos')),
    ),
    GoRoute(
      path: GoogleAccountScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: GoogleAccountScreen()),
    ),
    GoRoute(
      path: InstagramScreen.path,
      redirect: (context, state) =>
          MetaIntegrations.enabled.value ? null : MainShellScreen.path,
      builder: (context, state) => const NavBarShell(child: InstagramScreen()),
    ),
    GoRoute(
      path: InviteFriendsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: InviteFriendsScreen()),
    ),
    GoRoute(
      path: VoicePreferenceScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: VoicePreferenceScreen()),
    ),
    GoRoute(
      path: AccentColorScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: AccentColorScreen()),
    ),
    GoRoute(
      path: UsageScreen.path,
      builder: (context, state) => const NavBarShell(child: UsageScreen()),
    ),
    GoRoute(
      path: SubscriptionScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: SubscriptionScreen()),
    ),
    GoRoute(
      path: TrialPaywallScreen.path,
      builder: (context, state) {
        final offer = state.extra;
        return offer is TrialOffer
            ? TrialPaywallScreen(offer: offer)
            : const NavBarShell(child: PlansScreen());
      },
    ),
    GoRoute(
      path: PlansScreen.path,
      builder: (context, state) => const NavBarShell(child: PlansScreen()),
    ),
    GoRoute(
      path: FeedbackScreen.path,
      builder: (context, state) => const NavBarShell(child: FeedbackScreen()),
    ),
    GoRoute(
      path: SettingsScreen.path,
      builder: (context, state) => const NavBarShell(child: SettingsScreen()),
    ),
    GoRoute(
      path: AymaSettingsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: AymaSettingsScreen()),
    ),
    GoRoute(
      path: SkillsScreen.path,
      builder: (context, state) => const NavBarShell(child: SkillsScreen()),
    ),
    GoRoute(
      path: DeleteAccountScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: DeleteAccountScreen()),
    ),
    GoRoute(
      path: ReleaseNotesScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: ReleaseNotesScreen()),
    ),
    GoRoute(
      path: SharedReportScreen.path,
      builder: (context, state) =>
          SharedReportScreen(token: state.pathParameters['token']!),
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
