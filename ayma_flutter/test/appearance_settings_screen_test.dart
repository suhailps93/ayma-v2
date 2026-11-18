import 'package:ayma_flutter/screens/appearance_settings_screen.dart';
import 'package:ayma_flutter/screens/camera_color_picker_screen.dart';
import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
      : super(
          auth:
              MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
        );

  final List<Color> serverWrites = [];

  @override
  Future<Color?> getAccentColor() async => null;

  @override
  Future<void> setAccentColor(Color color) async {
    serverWrites.add(color);
  }
}

/// A stand-in camera screen that pops a sampled colour, exercising the
/// Appearance page's `context.push<Color>` return path.
class _StubCamera extends StatelessWidget {
  const _StubCamera({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('stubCameraReturn'),
            onPressed: () => Navigator.of(context).pop(color),
            child: const Text('return'),
          ),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The colour the stub camera hands back.
  const sampled = Color(0xFF123456);

  Widget host({
    required AccentColorController accent,
    ThemeController? theme,
  }) {
    final t = theme ?? ThemeController(initial: ThemeMode.dark);
    final router = GoRouter(
      initialLocation: AppearanceSettingsScreen.path,
      routes: [
        GoRoute(
          path: AppearanceSettingsScreen.path,
          builder: (_, __) => AppearanceSettingsScreen(
            controller: t,
            accentController: accent,
          ),
        ),
        GoRoute(
          path: CameraColorPickerScreen.path,
          builder: (_, __) => const _StubCamera(color: sampled),
        ),
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('SHELL')),
        ),
      ],
    );

    return AnimatedBuilder(
      animation: accent,
      builder: (context, _) => MaterialApp.router(
        theme: AymaTheme.lightWithAccent(accent.color),
        darkTheme: AymaTheme.darkWithAccent(accent.color),
        routerConfig: router,
      ),
    );
  }

  Future<String?> accentPref() async =>
      (await SharedPreferences.getInstance()).getString('accent_color_hex');

  // The accent section lives below the fold in a lazy ListView; scroll it in
  // (building it) before interacting.
  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> tapUseThisColor(WidgetTester tester) async {
    await scrollTo(tester, find.byKey(const Key('useThisColor')));
    await tester.tap(find.byKey(const Key('useThisColor')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Pumping an unrelated tree disposes the page's State — the exact trigger
  // for "the user left the page" (back arrow, Android back, swipe, nav away).
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  }

  testWidgets('default accent stays Cherry Fuchsia', (tester) async {
    final accent = AccentColorController(profileService: _FakeProfiles());
    expect(accent.color, AymaColors.accent);
    expect(accent.color, const Color(0xFFDA4B65));
  });

  testWidgets(
      'the combined page shows presets, the custom picker and the camera entry',
      (tester) async {
    final accent = AccentColorController(profileService: _FakeProfiles());
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Above the fold: the section header, the preset swatches and the
    // camera / eyedropper sampling entry.
    expect(find.text('Accent Color'), findsOneWidget);
    expect(find.byKey(const Key('accentPreset_cherry_fuchsia')), findsOneWidget);
    expect(find.byKey(const Key('accentPreset_green')), findsOneWidget);
    expect(find.byKey(const Key('accentPreset_ocean_blue')), findsOneWidget);
    expect(find.byKey(const Key('pickFromCamera')), findsOneWidget);
    // The hue strip of the full custom picker is inline on the same page.
    expect(find.byKey(const Key('hueStrip')), findsOneWidget);

    // Scroll the rest of the custom picker in — all on this one page.
    await scrollTo(tester, find.byKey(const Key('useThisColor')));
    expect(find.byKey(const Key('accentSaturation')), findsOneWidget);
    expect(find.byKey(const Key('accentBrightness')), findsOneWidget);
    expect(find.byKey(const Key('useThisColor')), findsOneWidget);
  });

  testWidgets('presets preview live WITHOUT persisting', (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('accentPreset_green')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Live repaint in-memory…
    expect(accent.color, const Color(0xFF2E9E5B));
    // …but nothing saved: no Firestore write, no local pref.
    expect(profiles.serverWrites, isEmpty);
    expect(await accentPref(), isNull);
  });

  testWidgets('the custom picker (hue drag) previews live WITHOUT persisting',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final before = accent.color;
    await tester.drag(find.byKey(const Key('hueStrip')), const Offset(80, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(accent.color, isNot(equals(before)));
    expect(profiles.serverWrites, isEmpty);
    expect(await accentPref(), isNull);
  });

  testWidgets('"Use this color" persists the pick (local + server)',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('accentPreset_green')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(profiles.serverWrites, isEmpty); // still only a preview

    await tapUseThisColor(tester);

    expect(accent.color, const Color(0xFF2E9E5B));
    expect(profiles.serverWrites, [const Color(0xFF2E9E5B)]);
    expect(await accentPref(), isNotNull);
  });

  testWidgets('leaving WITHOUT "Use this color" reverts and writes nothing',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    final saved = accent.color;
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('accentPreset_green')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(accent.color, isNot(equals(saved))); // previewed away

    await leave(tester);

    expect(accent.color, saved); // reverted to the saved baseline
    expect(profiles.serverWrites, isEmpty);
    expect(await accentPref(), isNull);
  });

  // Real push/pop navigation host: a stub Settings screen that pushes the
  // Appearance page, so popping disposes it exactly like the back arrow /
  // Android back does on device (the finalizeTree-locked path the
  // `pumpWidget`-replacement `leave()` above cannot exercise).
  Widget pushHost({required AccentColorController accent}) {
    final t = ThemeController(initial: ThemeMode.dark);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (ctx, __) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('goAppearance'),
                onPressed: () => ctx.push(AppearanceSettingsScreen.path),
                child: const Text('appearance'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: AppearanceSettingsScreen.path,
          builder: (_, __) => AppearanceSettingsScreen(
            controller: t,
            accentController: accent,
          ),
        ),
      ],
    );
    return AnimatedBuilder(
      animation: accent,
      builder: (context, _) => MaterialApp.router(
        theme: AymaTheme.lightWithAccent(accent.color),
        darkTheme: AymaTheme.darkWithAccent(accent.color),
        routerConfig: router,
      ),
    );
  }

  // Open Appearance, preview [preset], then pop back — the exact
  // pick-then-leave-without-saving gesture. Fixed pumps (not pumpAndSettle):
  // the live-preview orb animates forever and would never settle.
  Future<void> previewThenPop(WidgetTester tester, String preset) async {
    await tester.tap(find.byKey(const Key('goAppearance')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(Key('accentPreset_$preset')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    // Revert is deferred one frame (post dispose, tree unlocked); let it run.
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
      'leaving via a real pop reverts the live theme to the saved colour',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    final saved = accent.color;
    await tester.pumpWidget(pushHost(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await previewThenPop(tester, 'green');

    // Back on Settings: the in-memory accent is the saved colour again, no
    // locked-tree exception thrown during dispose, and nothing persisted.
    expect(tester.takeException(), isNull);
    expect(accent.color, saved);
    expect(profiles.serverWrites, isEmpty);
    expect(await accentPref(), isNull);
  });

  testWidgets(
      'leave twice without saving still reverts on the SECOND leave '
      '(founder revert-on-leave bug)', (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    final saved = accent.color;
    await tester.pumpWidget(pushHost(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // First leave without saving — reverts.
    await previewThenPop(tester, 'green');
    expect(accent.color, saved, reason: 'first leave reverts');

    // Second leave without saving — must ALSO revert (the reported defect:
    // the theme stayed on the unsaved preview after the second leave).
    await previewThenPop(tester, 'ocean_blue');
    expect(tester.takeException(), isNull);
    expect(accent.color, saved,
        reason: 'second leave must revert to the saved colour, not the preview');

    // The stored accent stayed the saved colour throughout — no write ever.
    expect(profiles.serverWrites, isEmpty);
    expect(await accentPref(), isNull);
  });

  testWidgets('committing then leaving keeps the committed colour',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('accentPreset_green')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tapUseThisColor(tester);
    final committed = accent.color;

    await leave(tester);

    expect(accent.color, committed); // no revert
    expect(profiles.serverWrites, [committed]); // no extra write on leave
  });

  testWidgets('reset previews the default WITHOUT persisting', (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await accent.set(const Color(0xFF3355AA));
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await scrollTo(tester, find.text('Reset to default'));
    await tester.tap(find.text('Reset to default'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Previews the default live, but only the earlier set() ever persisted.
    expect(accent.color, AymaColors.accent);
    expect(profiles.serverWrites, [const Color(0xFF3355AA)]);
  });

  testWidgets('camera return lands as an UNSAVED pick (preview only)',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('pickFromCamera')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // On the (stub) camera screen — hand a sampled colour back.
    await tester.tap(find.byKey(const Key('stubCameraReturn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // The sampled colour is previewed live…
    expect(accent.color, sampled);
    // …but nothing is saved — "Use this color" remains the sole persist.
    expect(profiles.serverWrites, isEmpty);
    expect(await accentPref(), isNull);
  });

  testWidgets('a committed non-preset colour becomes the Custom swatch',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(accent: accent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Sample from the camera, then commit it.
    await tester.tap(find.byKey(const Key('pickFromCamera')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stubCameraReturn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tapUseThisColor(tester);

    expect(accent.color, sampled);
    expect(accent.customColor, sampled);

    // The Custom swatch (top of the page) now renders; scroll back up to it.
    await tester.scrollUntilVisible(
        find.byKey(const Key('accentPreset_custom')), -150,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('accentPreset_custom')), findsOneWidget);
  });
}
