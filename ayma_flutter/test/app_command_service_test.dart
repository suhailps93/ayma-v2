import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  setUp(() {
    AppContext.instance.pendingExploreQuery = null;
    AppContext.instance.clear();
  });

  test('navigate command routes to the mapped path', () {
    final nav = <String>[];
    AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'navigate', 'screen': 'matches'});
    expect(nav, ['/matches']);
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
      'profile_details': '/settings/profile',
      'photos': '/settings/photos',
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
    AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'search_explore', 'query': '  hiking  '});
    expect(AppContext.instance.pendingExploreQuery, 'hiking');
    expect(nav, ['/explore']);
  });

  test('open_profile routes to that user', () {
    final nav = <String>[];
    AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'open_profile', 'uid': 'u-9'});
    expect(nav, ['/profile/user/u-9']);
  });

  test('open_dm_thread routes to the sorted-pair thread id', () {
    final nav = <String>[];
    final auth =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    AppCommandService(navigate: nav.add, auth: auth)
        .handleCommand({'action': 'open_dm_thread', 'uid': 'u-jordan'});
    expect(nav, ['/dm/me__u-jordan']);
  });

  test('app_action dispatches theme changes to the ThemeController', () {
    final theme = ThemeController();
    final svc = AppCommandService(themeController: theme);
    svc.handleCommand({'action': 'app_action', 'name': 'dark_mode'});
    expect(theme.mode, ThemeMode.dark);
    svc.handleCommand({'action': 'app_action', 'name': 'light_mode'});
    expect(theme.mode, ThemeMode.light);
    svc.handleCommand({'action': 'app_action', 'name': 'system_theme'});
    expect(theme.mode, ThemeMode.system);
  });

  test('app_action dispatches pause/resume matching to ProfileService', () {
    final profiles = _FakeProfileService();
    final svc = AppCommandService(profileService: profiles);
    svc.handleCommand({'action': 'app_action', 'name': 'pause_matching'});
    svc.handleCommand({'action': 'app_action', 'name': 'resume_matching'});
    expect(profiles.pausedCalls, [true, false]);
  });

  test('unknown screen / action / empty uid are ignored', () {
    final nav = <String>[];
    final svc = AppCommandService(navigate: nav.add)
      ..handleCommand({'action': 'navigate', 'screen': 'bogus'})
      ..handleCommand({'action': 'frobnicate'})
      ..handleCommand({'action': 'open_profile', 'uid': ''})
      ..handleCommand({'action': 'open_dm_thread', 'uid': ''})
      ..handleCommand({'action': 'app_action', 'name': 'delete_everything'});
    expect(nav, isEmpty);
    expect(svc, isNotNull);
  });
}
