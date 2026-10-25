import 'package:ayma_flutter/screens/voice_call_screen.dart';
import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart' hide Router;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfileService extends ProfileService {
  _FakeProfileService()
      : super(
          auth: MockFirebaseAuth(
              signedIn: true, mockUser: MockUser(uid: 'me')),
        );

  final List<bool> pausedCalls = [];

  @override
  Future<void> setPaused(bool paused) async {
    pausedCalls.add(paused);
  }
}

/// A [VoiceSessionController] pinned to `live` — just enough for
/// [VoiceCallScreen] to build; never starts a real session.
class _LiveVoice extends VoiceSessionController {
  _LiveVoice() : super(transcriptStore: TranscriptStore());

  @override
  VoiceSessionPhase get phase => VoiceSessionPhase.live;

  @override
  bool get agentSpeaking => false;

  @override
  bool get muted => false;
}

void main() {
  setUp(() {
    AppContext.instance.pendingExploreQuery = null;
    AppContext.instance.clear();
  });

  test('navigate command routes to the mapped path and reports true', () {
    final nav = <String>[];
    final ok = AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'navigate', 'screen': 'matches'});
    expect(nav, ['/matches']);
    expect(ok, isTrue);
  });

  test('navigate covers every nested profile/settings screen, not just the '
      '6 top-level tabs', () {
    const expected = {
      'ayma': '/',
      'explore': '/explore',
      'messages': '/messages',
      'profile': '/profile',
      'matches': '/matches',
      'story': '/profile/wiki',
      'settings': '/settings',
      'ayma_settings': '/settings/ayma',
      'profile_details': '/settings/profile',
      'photos': '/profile/me/public?edit=photos',
      'skills': '/skills',
      'voice_preference': '/settings/voice',
      'credits': '/profile/usage',
      'accent_color': '/settings/accent-color',
      'notifications': '/notifications',
      'notification_settings': '/notifications/prefs',
      'feedback': '/profile/feedback',
      'terms': '/terms',
      'privacy': '/privacy',
      'release_notes': '/whats-new',
    };
    for (final entry in expected.entries) {
      final nav = <String>[];
      AppCommandService(navigate: nav.add)
          .handleCommand({'action': 'navigate', 'screen': entry.key});
      expect(nav, [entry.value], reason: entry.key);
    }
  });

  test('search_explore stashes the trimmed query and opens Explore', () {
    final nav = <String>[];
    final ok = AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'search_explore', 'query': '  hiking  '});
    expect(AppContext.instance.pendingExploreQuery, 'hiking');
    expect(nav, ['/explore']);
    expect(ok, isTrue);
  });

  test('open_profile routes to that user', () {
    final nav = <String>[];
    final ok = AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'open_profile', 'uid': 'u-9'});
    expect(nav, ['/profile/user/u-9']);
    expect(ok, isTrue);
  });

  test('open_dm_thread routes to the sorted-pair thread id', () {
    final nav = <String>[];
    final auth =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    final ok = AppCommandService(navigate: nav.add, auth: auth)
        .handleCommand({'action': 'open_dm_thread', 'uid': 'u-jordan'});
    expect(nav, ['/dm/me__u-jordan']);
    expect(ok, isTrue);
  });

  test('app_action dispatches theme changes to the ThemeController', () {
    final theme = ThemeController();
    final svc = AppCommandService(themeController: theme);
    expect(
        svc.handleCommand({'action': 'app_action', 'name': 'dark_mode'}),
        isTrue);
    expect(theme.mode, ThemeMode.dark);
    svc.handleCommand({'action': 'app_action', 'name': 'light_mode'});
    expect(theme.mode, ThemeMode.light);
    svc.handleCommand({'action': 'app_action', 'name': 'system_theme'});
    expect(theme.mode, ThemeMode.system);
  });

  test('app_action accent_color sets the accent colour from a hex value',
      () async {
    SharedPreferences.setMockInitialValues({});
    final accent = AccentColorController(profileService: _FakeProfileService());
    final svc = AppCommandService(accentController: accent);
    expect(
        svc.handleCommand({
          'action': 'app_action',
          'name': 'accent_color',
          'value': '#2E9E5B',
        }),
        isTrue);
    expect(accent.color, const Color(0xFF2E9E5B));
    expect(
        svc.handleCommand(
            {'action': 'app_action', 'name': 'accent_color', 'value': 'green'}),
        isFalse,
        reason: 'only the resolved hex is accepted client-side');
    expect(accent.color, const Color(0xFF2E9E5B));
  });

  test('app_action dispatches pause/resume matching to ProfileService', () {
    final profiles = _FakeProfileService();
    final svc = AppCommandService(profileService: profiles);
    svc.handleCommand({'action': 'app_action', 'name': 'pause_matching'});
    svc.handleCommand({'action': 'app_action', 'name': 'resume_matching'});
    expect(profiles.pausedCalls, [true, false]);
  });

  test('unknown screen / action / empty uid are ignored and report false',
      () {
    final nav = <String>[];
    final svc = AppCommandService(navigate: nav.add);
    for (final cmd in <Map<String, dynamic>>[
      {'action': 'navigate', 'screen': 'bogus'},
      {'action': 'frobnicate'},
      {'action': 'open_profile', 'uid': ''},
      {'action': 'open_dm_thread', 'uid': ''},
      {'action': 'app_action', 'name': 'delete_everything'},
    ]) {
      expect(svc.handleCommand(cmd), isFalse, reason: '$cmd');
    }
    expect(nav, isEmpty);
  });

  // --- the live Firestore command loop (deliver -> execute -> ack) --------
  //
  // This is the half the founder bug lived in: the command doc being written
  // by the backend is not enough — the client must execute it AND report
  // back (`app_commands/ack` with the command's id), because the backend
  // tool now waits on that ack before telling the model the navigation
  // happened (skills/app_control.py `_await_ack`).

  group('command doc listener', () {
    late FakeFirebaseFirestore fs;
    late MockFirebaseAuth auth;
    late List<String> nav;
    late AppCommandService svc;

    DocumentReference<Map<String, dynamic>> pending() =>
        fs.doc('users/me/app_commands/pending');
    DocumentReference<Map<String, dynamic>> ack() =>
        fs.doc('users/me/app_commands/ack');

    setUp(() {
      fs = FakeFirebaseFirestore();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
      nav = <String>[];
      svc = AppCommandService(firestore: fs, auth: auth, navigate: nav.add)
        ..start();
    });

    tearDown(() async {
      await svc.stop();
    });

    test('executes a fresh command, acks it with ok=true, and deletes the '
        'pending doc', () async {
      await pending().set({
        'action': 'navigate',
        'screen': 'profile',
        'id': 'cmd-1',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(nav, ['/profile']);
      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'cmd-1');
      expect(ackDoc?['ok'], isTrue);
      expect((await pending().get()).exists, isFalse);
    });

    test('acks ok=false when the command cannot be executed', () async {
      await pending().set({
        'action': 'navigate',
        'screen': 'not-a-screen',
        'id': 'cmd-2',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(nav, isEmpty);
      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'cmd-2');
      expect(ackDoc?['ok'], isFalse);
      expect((await pending().get()).exists, isFalse);
    });

    test('a stale command (left behind while no listener was alive) is '
        'discarded unexecuted — the backend already told the user it did '
        'not work', () async {
      await pending().set({
        'action': 'navigate',
        'screen': 'profile',
        'id': 'cmd-old',
        'ts': Timestamp.fromDate(
            DateTime.now().subtract(const Duration(minutes: 2))),
      });
      await pumpEventQueue();

      expect(nav, isEmpty);
      expect((await ack().get()).exists, isFalse);
      expect((await pending().get()).exists, isFalse); // still cleaned up
    });

    test('a re-delivered snapshot of an already-handled id is not executed '
        'twice', () async {
      final cmd = {
        'action': 'navigate',
        'screen': 'profile',
        'id': 'cmd-3',
        'ts': Timestamp.now(),
      };
      await pending().set(cmd);
      await pumpEventQueue();
      await pending().set(cmd); // cache echo / duplicate write
      await pumpEventQueue();

      expect(nav, ['/profile']);
    });

    test('back-to-back commands each execute and each get their own ack',
        () async {
      await pending().set({
        'action': 'navigate',
        'screen': 'profile',
        'id': 'cmd-4',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();
      await pending().set({
        'action': 'navigate',
        'screen': 'matches',
        'id': 'cmd-5',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(nav, ['/profile', '/matches']);
      expect((await ack().get()).data()?['id'], 'cmd-5');
    });

    test('stop() ends the watch — a command written after stop is not '
        'executed', () async {
      await svc.stop();
      await pending().set({
        'action': 'navigate',
        'screen': 'profile',
        'id': 'cmd-6',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(nav, isEmpty);
      expect((await pending().get()).exists, isTrue);
    });
  });

  // --- navigation with the fullscreen voice view up ------------------------
  //
  // The founder was mid-call; the voice UI (inline bar or the fullscreen
  // [VoiceCallScreen], a pageless route pushed over the router's pages) must
  // never block Ayma-driven navigation: the handler navigates through the
  // app-wide router, not through any screen's own context, so a new page
  // lands on top regardless of what's showing.

  testWidgets(
      'a navigate command executes while the fullscreen voice view is up',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: navKey,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('chat screen')),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, __) => const Scaffold(body: Text('profile screen')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.text('chat screen'), findsOneWidget);

    // Open the fullscreen voice view exactly the way ChatScreen does
    // (`_openVoiceScreen`): an imperative, pageless MaterialPageRoute.
    final voice = _LiveVoice();
    addTearDown(voice.dispose);
    navKey.currentState!.push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => VoiceCallScreen(voice: voice),
    ));
    // Discrete pumps, not pumpAndSettle — the orb animates continuously.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('chat screen'), findsNothing);
    expect(find.byType(VoiceCallScreen), findsOneWidget);

    // Ayma's command lands mid-call: the handler routes through the global
    // router and the destination must actually appear on top.
    final ok = AppCommandService(navigate: router.push)
        .handleCommand({'action': 'navigate', 'screen': 'profile'});
    expect(ok, isTrue);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('profile screen'), findsOneWidget);
  });

  group('shared listener ownership (voice + foreground)', () {
    late FakeFirebaseFirestore fs;
    late MockFirebaseAuth auth;
    late List<String> nav;

    Future<void> send(String id) => fs.doc('users/me/app_commands/pending').set({
          'action': 'navigate',
          'screen': 'profile',
          'id': id,
          'ts': Timestamp.now(),
        });

    setUp(() {
      fs = FakeFirebaseFirestore();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
      nav = <String>[];
    });

    test('a foregrounded app executes and acks a command with no voice call',
        () async {
      final svc =
          AppCommandService(firestore: fs, auth: auth, navigate: nav.add);
      await svc.setForeground(true);
      await send('t-1');
      await pumpEventQueue();

      expect(nav, ['/profile']);
      final ack = (await fs.doc('users/me/app_commands/ack').get()).data();
      expect(ack?['id'], 't-1');
      expect(ack?['ok'], isTrue);
      await svc.setForeground(false);
    });

    test('a backgrounded app never listens, so nothing is executed',
        () async {
      final svc =
          AppCommandService(firestore: fs, auth: auth, navigate: nav.add);
      await svc.setForeground(true);
      await svc.setForeground(false);
      await send('t-2');
      await pumpEventQueue();

      expect(nav, isEmpty);
      expect((await fs.doc('users/me/app_commands/ack').get()).exists, isFalse);
    });

    test('search_explore: once Explore reports the loaded results they are '
        'added to the ack so the tool can return them', () async {
      final svc =
          AppCommandService(firestore: fs, auth: auth, navigate: nav.add);
      await svc.setForeground(true);
      await fs.doc('users/me/app_commands/pending').set({
        'action': 'search_explore',
        'query': 'hiking',
        'id': 'cmd-x',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();
      expect((await fs.doc('users/me/app_commands/ack').get()).data()?['result'], isNull);

      // A report for some other search is ignored.
      AppContext.instance.exploreReport.value =
          ExploreReport(query: 'cooking', summary: 'wrong');
      await pumpEventQueue();
      expect((await fs.doc('users/me/app_commands/ack').get()).data()?['result'], isNull);

      AppContext.instance.exploreReport.value = ExploreReport(
          query: 'hiking', summary: 'Search "hiking": 1 person: Ash, 29');
      await pumpEventQueue();

      final doc = (await fs.doc('users/me/app_commands/ack').get()).data();
      expect(doc?['id'], 'cmd-x');
      expect(doc?['ok'], isTrue);
      expect(doc?['result'], 'Search "hiking": 1 person: Ash, 29');
      await svc.setForeground(false);
    });

    test('ending a voice call keeps the foreground listener alive', () async {
      final svc =
          AppCommandService(firestore: fs, auth: auth, navigate: nav.add);
      await svc.setForeground(true);
      svc.start();
      await svc.stop();
      await send('t-3');
      await pumpEventQueue();

      expect(nav, ['/profile']);
      await svc.setForeground(false);
    });

    test('a stale command is discarded unexecuted, not run on resume',
        () async {
      final svc =
          AppCommandService(firestore: fs, auth: auth, navigate: nav.add);
      await fs.doc('users/me/app_commands/pending').set({
        'action': 'navigate',
        'screen': 'profile',
        'id': 't-4',
        'ts': Timestamp.fromDate(
            DateTime.now().subtract(const Duration(minutes: 2))),
      });
      await svc.setForeground(true);
      await pumpEventQueue();

      expect(nav, isEmpty);
      await svc.setForeground(false);
    });
  });
}
