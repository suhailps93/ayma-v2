// What the layout matrix pumps: every routed screen and the main overlays.
// See `test/layout_matrix_test.dart`.
import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/screens/accent_color_screen.dart';
import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/screens/ayma_settings_screen.dart';
import 'package:ayma_flutter/screens/biometric_consent_screen.dart';
import 'package:ayma_flutter/screens/biometric_consent_settings_screen.dart';
import 'package:ayma_flutter/screens/biometric_info_screen.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/complete_profile_screen.dart';
import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/screens/delete_account_screen.dart';
import 'package:ayma_flutter/screens/developer_screen.dart';
import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/feedback_screen.dart';
import 'package:ayma_flutter/screens/google_account_screen.dart';
import 'package:ayma_flutter/screens/instagram_screen.dart';
import 'package:ayma_flutter/screens/invite_friends_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/screens/matches_screen.dart';
import 'package:ayma_flutter/screens/messages_screen.dart';
import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/screens/notification_center_screen.dart';
import 'package:ayma_flutter/screens/notification_prefs_screen.dart';
import 'package:ayma_flutter/screens/physical_attributes_report_screen.dart';
import 'package:ayma_flutter/screens/plan_screen.dart';
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/screens/privacy_screen.dart';
import 'package:ayma_flutter/screens/profile_settings_screen.dart';
import 'package:ayma_flutter/screens/profile_tab_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/screens/recovery_screen.dart';
import 'package:ayma_flutter/screens/release_notes_screen.dart';
import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/screens/shared_report_screen.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/screens/skills_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/screens/trial_paywall_screen.dart';
import 'package:ayma_flutter/screens/underage_screen.dart';
import 'package:ayma_flutter/screens/voice_preference_screen.dart';
import 'package:ayma_flutter/screens/voice_call_screen.dart';
import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/services/google_account_service.dart';
import 'package:ayma_flutter/services/instagram_service.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/ayma_chat_modal.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/nav_bar_shell.dart';
import 'package:ayma_flutter/widgets/oauth_code_dialog.dart';
import 'package:ayma_flutter/widgets/out_of_credits.dart';
import 'package:ayma_flutter/widgets/share_report_sheet.dart';
import 'package:ayma_flutter/widgets/ayma_toast.dart';
import 'package:ayma_flutter/screens/push_primer_dialog.dart';
import 'package:ayma_flutter/services/photo_service.dart';
import 'package:ayma_flutter/services/push_permission.dart';
import 'package:ayma_flutter/widgets/body_report_view.dart';
import 'package:ayma_flutter/widgets/face_report_view.dart';
import 'package:ayma_flutter/widgets/image_viewer.dart';
import 'package:ayma_flutter/widgets/profile_photo_editor.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show PeriodUnit;
import 'package:shared_preferences/shared_preferences.dart';

import 'layout_fakes.dart';
import 'layout_matrix.dart';

/// Every route in `appRouter`, keyed by its path pattern, mapped to the
/// screen exactly as that route builds it (same [NavBarShell] wrapping) but
/// with fake services.
Map<String, Widget Function()> layoutRoutes([FakeFirebaseFirestore? seeded]) {
  final fs = seeded ?? FakeFirebaseFirestore();
  final api = layoutApi();
  final profiles = ProfileService(auth: kLayoutAuth, firestore: fs);
  final dms = DmService(auth: kLayoutAuth, firestore: fs, api: api);
  final matches = MatchService(auth: kLayoutAuth, firestore: fs, api: api);
  final notifications = NotificationService(auth: kLayoutAuth, firestore: fs);
  Widget shell(Widget child) => NavBarShell(child: child);
  return {
    SplashScreen.path: () => SplashScreen(apiClient: api, auth: kLayoutAuth),
    UnderageScreen.path: () => UnderageScreen(signOut: () async {}),
    SignInScreen.path: () => SignInScreen(
      auth: AuthService(auth: kLayoutAuth, profileService: profiles),
      apiClient: api,
      voiceController: LayoutFakeVoice(),
    ),
    PreboardingFlowScreen.path: () => shell(
      PreboardingFlowScreen(profileService: profiles, apiClient: api),
    ),
    MainShellScreen.path: () => MainShellScreen(
      voiceController: LayoutFakeVoice(),
      transcriptStore: TranscriptStore(),
    ),
    ChatScreen.path: () => ChatScreen(
      marketing: true,
      apiClient: api,
      voiceController: LayoutFakeVoice(),
      transcriptStore: TranscriptStore(),
    ),
    ProfileSettingsScreen.path: () => shell(
      ProfileSettingsScreen(profileService: profiles, apiClient: api),
    ),
    CompleteProfileScreen.path: () =>
        shell(CompleteProfileScreen(apiClient: api)),
    StoryEditorScreen.path: () =>
        shell(StoryEditorScreen(api: api, myUid: 'me')),
    '/dm/:threadId': () => shell(
      DmThreadScreen(
        threadId: 'her__me',
        title: kLongName,
        dmService: dms,
        apiClient: api,
      ),
    ),
    '/match/:matchId': () =>
        shell(MatchReportScreen(matchId: 'm1', apiClient: api)),
    '/match-request/:matchId': () => shell(
      MatchDetailScreen(matchId: 'm1', service: matches, api: api),
    ),
    DeepDiveReportScreen.path: () =>
        shell(DeepDiveReportScreen(reportId: 'r1', apiClient: api)),
    PhysicalAttributesReportScreen.path: () =>
        shell(PhysicalAttributesReportScreen(reportId: 'r1', apiClient: api)),
    AppearanceReportScreen.path: () => shell(
      AppearanceReportScreen(reportId: 'r1', apiClient: api, myUid: 'me'),
    ),
    PublicProfileScreen.path: () => PublicProfileScreen(uid: 'her', api: api),
    ExploreScreen.path: () => shell(
      ExploreScreen(apiClient: api, initialQuery: 'climbers in Denver'),
    ),
    MatchesScreen.path: () =>
        shell(MatchesScreen(matchService: matches, api: api)),
    MessagesScreen.path: () => shell(
      MessagesScreen(dmService: dms, matchService: matches, apiClient: api),
    ),
    ProfileTabScreen.path: () =>
        shell(ProfileTabScreen(auth: kLayoutAuth, apiClient: api)),
    NotificationCenterScreen.path: () => NavBarShell(
      notificationsActive: true,
      child: NotificationCenterScreen(service: notifications, apiClient: api),
    ),
    NotificationPrefsScreen.path: () =>
        shell(NotificationPrefsScreen(service: notifications)),
    MyPublicProfileScreen.path: () =>
        shell(MyPublicProfileScreen(apiClient: api, myUid: 'me')),
    GoogleAccountScreen.path: () =>
        shell(GoogleAccountScreen(service: GoogleAccountService(api: api))),
    InstagramScreen.path: () => shell(
      InstagramScreen(
        service: InstagramService(api: api, auth: kLayoutAuth, firestore: fs),
      ),
    ),
    InviteFriendsScreen.path: () =>
        shell(InviteFriendsScreen(api: api, share: (_) async {})),
    VoicePreferenceScreen.path: () =>
        shell(VoicePreferenceScreen(api: api, profileService: profiles)),
    AccentColorScreen.path: () =>
        shell(
      AccentColorScreen(
        controller: AccentColorController(profileService: profiles),
      ),
    ),
    PlanScreen.path: () => shell(PlanScreen(service: LayoutFakeRc(), api: api)),
    TrialPaywallScreen.path: () => TrialPaywallScreen(
      offer: TrialOffer(
        plan: RevenueCatService.fallbackPlans.last,
        unit: PeriodUnit.day,
        value: 30,
      ),
      service: LayoutFakeRc(),
      api: api,
    ),
    DeveloperScreen.path: () =>
        shell(DeveloperScreen(api: api, auth: kLayoutAuth)),
    FeedbackScreen.path: () => shell(FeedbackScreen(api: api)),
    SettingsScreen.path: () => shell(
      SettingsScreen(
        controller: ThemeController(),
        profileService: profiles,
        api: api,
      ),
    ),
    AymaSettingsScreen.path: () => shell(AymaSettingsScreen(api: api)),
    SkillsScreen.path: () =>
        shell(SkillsScreen(profileService: profiles, api: api)),
    BiometricConsentScreen.path: () => BiometricConsentScreen(api: api),
    BiometricInfoScreen.path: () => const BiometricInfoScreen(),
    BiometricConsentSettingsScreen.path: () => shell(
      BiometricConsentSettingsScreen(api: api, auth: kLayoutAuth),
    ),
    DeleteAccountScreen.path: () =>
        shell(DeleteAccountScreen(api: api, auth: kLayoutAuth)),
    ReleaseNotesScreen.path: () => shell(const ReleaseNotesScreen()),
    SharedReportScreen.path: () =>
        SharedReportScreen(token: 'tok', apiClient: api),
    RecoveryScreen.path: () => RecoveryScreen(apiClient: api),
    TermsScreen.path: () => const TermsScreen(),
    PrivacyScreen.path: () => const PrivacyScreen(),
  };
}

/// Overlays: the sheets, dialogs and toasts, each opened over a plain page.
Map<String, Future<void> Function(BuildContext)> layoutOverlays() {
  final api = layoutApi();
  final voice = LayoutFakeVoice();
  return {
    // The founder's 42px overflow: the page-context popup over Story, with
    // the pinned "Story" chip above the composer and the nav bar copy below.
    'page-context chat sheet (pinned Story chip)': (context) =>
        showAymaChatModal(
          context,
          persistentBottomBar: (_) =>
              AymaTabBar(index: -1, voice: voice, onSelected: (_) {}),
          persistentBottomBarHeight: AymaTabBar.heightFor,
          builder: (_) => ChatScreen(
            apiClient: api,
            transcriptStore: TranscriptStore(),
            voiceController: voice,
            pageContext: const ScreenContext(screen: 'story'),
            onExpandRequested: () {},
          ),
        ),
    // A live call with Ayma told to "shut up": the quiet chip (with its
    // Unmute button) above the composer and the quiet orb in the nav bar.
    'chat sheet while Ayma is quiet': (context) {
      final quiet = LayoutFakeVoice(quiet: true);
      return showAymaChatModal(
        context,
        persistentBottomBar: (_) =>
            AymaTabBar(index: -1, voice: quiet, onSelected: (_) {}),
        persistentBottomBarHeight: AymaTabBar.heightFor,
        builder: (_) => ChatScreen(
          apiClient: api,
          transcriptStore: TranscriptStore(),
          voiceController: quiet,
          onExpandRequested: () {},
        ),
      );
    },
    'voice call screen while Ayma is quiet': (context) =>
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) =>
                VoiceCallScreen(voice: LayoutFakeVoice(quiet: true)),
          ),
        ),
    'Ask Ayma correction sheet': (context) => showAskAymaOverlay(
      context,
      api: api,
      ctx: const AskAymaContext(
        pageId: 'identity',
        sectionTitle: 'A very long section title that keeps on going',
        selectedText: kLongText,
      ),
    ),
    'out-of-credits sheet': (context) =>
        showOutOfCreditsSheet(context, service: LayoutFakeRc()),
    'share report sheet': (context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ShareReportSheet(
        reportType: 'deep_dive',
        reportId: 'r1',
        apiClient: api,
      ),
    ),
    'OAuth code dialog': (context) => promptForOAuthCode(context),
    // No Firebase in tests: the permission read fails, which the primer
    // treats as "not asked yet" — so the dialog shows.
    'push primer dialog': (context) =>
        showPushPrimer(context, permission: PushPermission()),
    'body report sheet': (context) =>
        openStoredBodyReport(context, api: api, reportId: 'r1'),
    'face report sheet': (context) =>
        openStoredFaceReport(context, api: api, reportId: 'r1'),
    'profile photo editor sheet': (context) => ProfilePhotoEditor.show(
      context,
      service: PhotoService(
        api: api,
        auth: kLayoutAuth,
        firestore: FakeFirebaseFirestore(),
      ),
    ),
    'image viewer': (context) => AymaImageViewer.open(context, url: ''),
    // The app's one toast (`AymaToast`, mounted by `AymaToastHost` in the
    // matrix's MaterialApp.builder exactly as in main.dart).
    'toast with action (long message)': (context) async {
      AymaToast.show(
        context,
        kLongText,
        kind: AymaToastKind.error,
        action: AymaToastAction(label: 'Try again', onPressed: () {}),
      );
    },
    'toast (short success)': (context) async {
      AymaToast.show(context, 'Saved', kind: AymaToastKind.success);
    },
  };
}

/// Defines the matrix tests for shard [shard] of [shards] (round-robin over
/// every screen and overlay), so `flutter test` runs the shards in parallel.
/// Shard 0 also checks that every `appRouter` route has an entry.
void defineLayoutMatrix({required int shard, required int shards}) {
  // Building the route/overlay tables below (to enumerate them) constructs
  // services that touch the binding, so it must be the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TabRequest.instance.consume();
    isPageContextAymaPopupOpen = false;
    AppContext.instance.set(screen: '');
  });

  if (shard == 0) {
    test('every route in appRouter has a layout-matrix entry', () {
      final paths = <String>[
        for (final r in appRouter.configuration.routes)
          if (r is GoRoute) r.path,
      ];
      expect(paths, isNotEmpty);
      expect(layoutRoutes().keys.toSet(), containsAll(paths));
    });
  }

  final screens = layoutRoutes().keys.toList();
  final overlays = layoutOverlays().keys.toList();
  for (var i = 0; i < screens.length + overlays.length; i++) {
    if (i % shards != shard) continue;
    if (i < screens.length) {
      final path = screens[i];
      testWidgets('screen $path', (tester) async {
        final fs = await layoutFirestore();
        await expectLayoutRobust(tester, layoutRoutes(fs)[path]!);
      });
    } else {
      final name = overlays[i - screens.length];
      testWidgets(name, (tester) async {
        await expectLayoutRobust(
          tester,
          () => const Scaffold(body: SizedBox.expand()),
          open: layoutOverlays()[name]!,
        );
      });
    }
  }
}
