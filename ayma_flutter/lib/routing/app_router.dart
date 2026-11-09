import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../dev_mode.dart';
import '../features/date_sim/date_sim_screen.dart';
import '../features/practice_date/practice_debrief_screen.dart';
import '../features/practice_date/practice_screen.dart';
import '../services/api_client.dart';
import '../services/auth_session_state.dart';
import '../services/connection_heartbeat.dart';
import '../services/deep_link_queue.dart';
import '../services/share_kit.dart';
import '../services/meta_integrations.dart';
import '../services/app_context.dart';
import '../services/screen_capture.dart';
import '../services/biometric_consent.dart';
import '../services/dev_panel_session.dart';
import '../services/tab_request.dart';
import '../screens/biometric_consent_screen.dart';
import '../screens/biometric_consent_settings_screen.dart';
import '../screens/biometric_info_screen.dart';
import '../screens/accent_color_screen.dart';
import '../screens/appearance_report_screen.dart';
import '../screens/appearance_settings_screen.dart';
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
import '../screens/connect_agent_screen.dart';
import '../screens/google_account_screen.dart';
import '../screens/instagram_screen.dart';
import '../screens/invite_friends_screen.dart';
import '../screens/my_public_profile_screen.dart';
import '../screens/profile_proposals_screen.dart';
import '../screens/physical_attributes_report_screen.dart';
import '../screens/preboarding_flow_screen.dart';
import '../screens/privacy_screen.dart';
import '../screens/profile_tab_screen.dart';
import '../screens/story_editor_screen.dart';
import '../screens/privacy_settings_screen.dart';
import '../screens/profile_settings_screen.dart';
import '../screens/public_profile_screen.dart';
import '../screens/recovery_screen.dart';
import '../screens/delete_account_screen.dart';
import '../screens/underage_screen.dart';
import '../screens/release_notes_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/shared_profile_link_screen.dart';
import '../screens/shared_report_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/skills_screen.dart';
import '../screens/plan_screen.dart';
import '../screens/developer_screen.dart';
import '../screens/admin_feedback_screen.dart';
import '../screens/trial_paywall_screen.dart';
import '../services/revenuecat_service.dart';
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
///   [RecoveryScreen]) — there is no signed-in
///   session yet for the bar's tabs to mean anything, and tapping one would
///   just bounce straight back here;
/// - the legacy legal routes ([TermsScreen], [PrivacyScreen]) — they are
///   not screens at all any more: arriving there opens the hosted page in
///   the browser and goes straight back (see `LegalRedirect`), so there
///   is nothing for the bar to wrap;
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
/// Where a signed-in user without the face-matching consent may still be.
const _consentPendingAllowed = {
  BiometricConsentScreen.path,
  BiometricInfoScreen.path,
  SplashScreen.path,
  TermsScreen.path,
  PrivacyScreen.path,
  RecoveryScreen.path,
  UnderageScreen.path,
};

// Where a signed-in user whose account is soft-deleted (recovery required, B9)
// may still be: only the recovery screen itself, splash (which re-bootstraps
// and re-routes), and the legal pages it links to.
const _recoveryPendingAllowed = {
  RecoveryScreen.path,
  SplashScreen.path,
  TermsScreen.path,
  PrivacyScreen.path,
};

void setupAuthDeepLinkDrain([
  FirebaseAuth? auth,
  void Function(String path)? navigate,
]) {
  final nav = navigate ?? navigateToRoute;
  (auth ?? FirebaseAuth.instance).authStateChanges().listen((user) {
    if (user != null && !user.isAnonymous) {
      DeepLinkQueue.instance.drainPostAuth(
        user.uid,
        navigate: (path) => nav(path),
      );
      // A page-share link that arrived signed-out: its target route was
      // stashed by the link screen — open it now sign-in has landed.
      final pendingShare = PendingPageShare.take();
      if (pendingShare.isNotEmpty) nav(pendingShare);
    }
  });
}

final appRouter = GoRouter(
  initialLocation: SplashScreen.path,
  // Lets screens re-assert their voice screen-context when a child route pops.
  observers: [screenRouteObserver, screenPopupTracker, heartbeatRouteObserver],
  // Sign-in gate (§3.3): unauthenticated users can only reach the sign-in,
  // splash, terms and recovery screens; everything else bounces to sign-in.
  redirect: (context, state) {
    // Read the router-facing [AuthSessionState] first (updated synchronously by
    // the auth listener in main.dart), falling back to FirebaseAuth so the gate
    // is correct even before the first listener tick. AuthSessionState is a pure
    // ChangeNotifier, so this stays safe in Firebase-less test suites.
    final user = FirebaseAuth.instance.currentUser;
    final signedIn = AuthSessionState.instance.signedIn ||
        (user != null && !user.isAnonymous);
    final loc = state.matchedLocation;
    const open = {
      SignInScreen.path,
      SplashScreen.path,
      TermsScreen.path,
      PrivacyScreen.path,
      BiometricInfoScreen.path,
      RecoveryScreen.path,
    };
    // A shared-report link is public (the snapshot needs no auth), and a
    // page-share link resolves its own target (teaser + stash signed-out).
    if (!signedIn &&
        !open.contains(loc) &&
        !loc.startsWith('/s/') &&
        !loc.startsWith('/p/')) {
      return SignInScreen.path;
    }
    if (signedIn && loc == SignInScreen.path) return SplashScreen.path;
    // Soft-deleted account (B9, §3.6): recovery takes precedence over the
    // consent gate. A deleted account's consent record was quarantined too, so
    // its gated calls would otherwise read as "consent required" and strand the
    // user on the consent screen, where recording consent is itself refused
    // until recovery. Route to the recovery screen first.
    if (signedIn &&
        RecoveryRequiredState.instance.required &&
        !_recoveryPendingAllowed.contains(loc)) {
      return RecoveryScreen.path;
    }
    // Mandatory face-matching consent: once the server says this account
    // doesn't have it, only the one-time consent screen (and the legal pages)
    // stay reachable.
    if (signedIn &&
        BiometricConsentState.instance.required &&
        !_consentPendingAllowed.contains(loc)) {
      return BiometricConsentScreen.path;
    }
    return null;
  },
  refreshListenable: Listenable.merge([
    BiometricConsentState.instance,
    RecoveryRequiredState.instance,
    AuthSessionState.instance,
  ]),
  routes: [
    GoRoute(
      path: SplashScreen.path,
      builder: (context, state) => SplashScreen(apiClient: ApiClient()),
    ),
    GoRoute(
      path: UnderageScreen.path,
      builder: (context, state) => const UnderageScreen(),
    ),
    // The feature tour (§11.2a) is no longer a route: it's an interactive
    // coach-mark overlay the main shell hosts over its own live UI (so it can
    // spotlight the real composer, orb and tabs). The shell's gate auto-shows
    // it; Settings/Dev replay via `TourRequest` + `context.go('/')`.
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
      // clearance math (`AymaTabBar.heightFor`). Wrapping it here too
      // would stack a second bar under/behind the first.
      path: PublicProfileScreen.path,
      builder: (context, state) =>
          PublicProfileScreen(uid: state.pathParameters['uid']!),
    ),
    // Practice Date (hackathon deliverable B). The debrief route is listed
    // first; go_router matches the 3-segment pattern before the 2-segment one.
    GoRoute(
      path: PracticeDebriefScreen.path,
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? const {};
        return PracticeDebriefScreen(
          uid: state.pathParameters['uid']!,
          sessionId: (extra['session_id'] as String?) ?? '',
          name: (extra['name'] as String?) ?? '',
        );
      },
    ),
    GoRoute(
      path: PracticeScreen.path,
      builder: (context, state) {
        // `?voice=1` (or an extra map with voice: true) is Ayma's
        // voice-mode practice launch: the screen auto-starts the
        // practice voice call (bug DC2eUbckGA6J0ufDZpRG).
        final extra = state.extra;
        final extraMap = extra is Map ? extra : const {};
        return PracticeScreen(
          uid: state.pathParameters['uid']!,
          name: extra is String
              ? extra
              : (extraMap['name'] as String? ?? ''),
          autoStartVoice: state.uri.queryParameters['voice'] == '1' ||
              extraMap['voice'] == true,
        );
      },
    ),
    // AI Date Simulation (hackathon flagship): the two-persona conversation
    // preview. Entered from a match's profile with their name.
    GoRoute(
      path: DateSimScreen.path,
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? const {};
        // Reopen a specific (running or finished) sim when a `sim_id` is given
        // — the deep link's query param (completion notification) or `extra`.
        // A notification open also carries `from=notification`, so Done
        // navigates to the origin profile instead of popping to the
        // Notifications list / boot shell beneath (Scout 2289).
        final simId =
            state.uri.queryParameters['sim_id'] ?? extra['sim_id'] as String?;
        final fromNotification =
            state.uri.queryParameters['from'] == 'notification' ||
            extra['from'] == 'notification';
        return DateSimScreen(
          uid: state.pathParameters['uid']!,
          name: (extra['name'] as String?) ?? '',
          simId: simId,
          openedFromNotification: fromNotification,
        );
      },
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
      path: MyPublicProfileScreen.path,
      builder: (context, state) =>
          NavBarShell(
              child: MyPublicProfileScreen(
                  openPhotoEditor:
                      state.uri.queryParameters['edit'] == 'photos')),
    ),
    GoRoute(
      path: ProfileProposalsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: ProfileProposalsScreen()),
    ),
    GoRoute(
      path: GoogleAccountScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: GoogleAccountScreen()),
    ),
    GoRoute(
      path: ConnectAgentScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: ConnectAgentScreen()),
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
      path: PlanScreen.path,
      builder: (context, state) => const NavBarShell(child: PlanScreen()),
    ),
    GoRoute(
      path: TrialPaywallScreen.path,
      builder: (context, state) {
        final offer = state.extra;
        return offer is TrialOffer
            ? TrialPaywallScreen(offer: offer)
            : const NavBarShell(child: PlanScreen());
      },
    ),
    // Dev-only routes. They stay in the table (so the app-registry invariant
    // holds), but every one is hard-gated by the compile-time dev-mode flag:
    // when dev mode is off (`kDevModeEnabled == false` — every customer /
    // store build, the fail-safe default), each redirects to the main shell,
    // so even a deep link or stale link cannot reach the Developer panel or
    // anything behind it. The seven-tap unlock gesture is a no-op then too
    // (settings_screen.dart). Internal / dev builds opt in with
    // `--dart-define=ENABLE_DEV_MODE=true` (scripts/build-apk.sh).
    GoRoute(
      path: DeveloperScreen.path,
      redirect: (context, state) =>
          devModeEnabled ? null : MainShellScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: DeveloperScreen()),
    ),
    GoRoute(
      // "Ayma's Notes" — the full analytical picture ("the intelligence
      // beneath the portrait"). Dev-only on purpose: reached only from the
      // unlocked Developer panel, and this redirect bounces anyone who tries
      // to deep-link it unless dev mode is on AND the panel is unlocked, so no
      // normal-user path (and no stale link) can surface the analysis layer
      // (§11.2).
      path: AymaNotesScreen.path,
      redirect: (context, state) =>
          devModeEnabled && DevPanelSession.instance.unlocked.value
              ? null
              : MainShellScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: AymaNotesScreen()),
    ),
    GoRoute(
      path: AdminFeedbackScreen.path,
      redirect: (context, state) =>
          devModeEnabled ? null : MainShellScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: AdminFeedbackScreen()),
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
      path: AppearanceSettingsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: AppearanceSettingsScreen()),
    ),
    GoRoute(
      path: PrivacySettingsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: PrivacySettingsScreen()),
    ),
    GoRoute(
      path: SkillsScreen.path,
      builder: (context, state) => const NavBarShell(child: SkillsScreen()),
    ),
    GoRoute(
      path: BiometricConsentScreen.path,
      builder: (context, state) => const BiometricConsentScreen(),
    ),
    GoRoute(
      path: BiometricInfoScreen.path,
      builder: (context, state) => const BiometricInfoScreen(),
    ),
    GoRoute(
      path: BiometricConsentSettingsScreen.path,
      builder: (context, state) =>
          const NavBarShell(child: BiometricConsentSettingsScreen()),
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
      path: SharedProfileLinkScreen.path,
      builder: (context, state) =>
          SharedProfileLinkScreen(token: state.pathParameters['token']!),
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

/// Navigates to [path] for a notification deep link, a post-auth queued deep
/// link or an Ayma `navigate` command, but never stacks a second copy of the
/// root shell ([MainShellScreen.path]) on top of a live one.
///
/// The root shell is always at the base of the stack, and two `MainShellScreen`
/// instances alive at once each mount the SAME shared feature-tour anchor
/// GlobalKeys (`TourAnchors.keyFor` — the chat composer, the orb, the tab bar).
/// Two live widgets holding one GlobalKey is a Flutter "Duplicate GlobalKey"
/// error that retakes the inactive element mid-layout, mutates a `RenderFlex`
/// and corrupts the tree (J1: the warm web-search notification tap used to
/// `push('/')` a second shell over the open one). So returning to the root
/// shell is a `go` (reuse the single existing shell); every other route still
/// `push`es, so Back returns to the prior screen.
///
/// When a [context] is given the nearest router is used (so a caller inside the
/// widget tree, e.g. the notification center, routes through the navigator it
/// lives under — and tests that pump it with their own router observe the
/// navigation); otherwise the app-wide [appRouter] (the context-less tap /
/// drain / Ayma-command paths). [router] overrides both, for direct unit tests.
///
/// The root shell holds four tabs and can already be live on any of them (J1
/// LEG2: `go` reuses the single shell rather than `push`ing a duplicate). The
/// root-shell deep link (`deepLinkToRoute` → '/', the web-search/skill-result/
/// chat notification) means "show the chat", where the report card lives — so
/// before the `go` we post a [TabRequest] for the Ayma/chat tab. A reused shell
/// switches to it via its live `_consumeTabRequest` listener; a freshly-built
/// one consumes the same request in `initState` (and already defaults to chat).
/// Deep links that target another tab resolve to their own routes (`/matches`,
/// …) and take the `push` branch, so they are untouched (§11.5).
void navigateToRoute(String path, {BuildContext? context, GoRouter? router}) {
  final r = router ?? (context != null ? GoRouter.of(context) : appRouter);
  if (path == MainShellScreen.path) {
    TabRequest.instance.request(MainShellScreen.aymaTabIndex);
    r.go(path);
  } else {
    r.push(path);
  }
}
