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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
          builder: (_, __) => const Scaffold(body: Text('CAMERA PICKER SCREEN')),
        ),
        GoRoute(
          path: '/settings/accent-color',
          builder: (_, __) => const Scaffold(body: Text('ACCENT SCREEN')),
        ),
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('SHELL')),
        ),
      ],
    );

    return MaterialApp.router(
      theme: AymaTheme.lightWithAccent(accent.color),
      darkTheme: AymaTheme.darkWithAccent(accent.color),
      routerConfig: router,
    );
  }

  testWidgets('default accent stays Cherry Fuchsia', (tester) async {
    final accent = AccentColorController(profileService: _FakeProfiles());
    expect(accent.color, AymaColors.accent);
    expect(accent.color, const Color(0xFFDA4B65));
  });

  testWidgets(
      'Appearance screen displays preset swatches, updates accent on tap, and offers Pick from camera option',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(
      initial: AymaColors.accent,
      profileService: profiles,
    );

    await tester.pumpWidget(host(accent: accent));
    await tester.pumpAndSettle();

    // Verify Accent Color title exists
    expect(find.text('Accent Color'), findsOneWidget);

    // Verify preset swatches exist (e.g. cherry_fuchsia, green, ocean_blue)
    expect(find.byKey(const Key('accentPreset_cherry_fuchsia')), findsOneWidget);
    expect(find.byKey(const Key('accentPreset_green')), findsOneWidget);
    expect(find.byKey(const Key('accentPreset_ocean_blue')), findsOneWidget);

    // Verify Pick from camera button exists alongside swatches
    expect(find.byKey(const Key('pickFromCamera')), findsOneWidget);

    // Tap green preset
    await tester.tap(find.byKey(const Key('accentPreset_green')));
    await tester.pumpAndSettle();

    expect(accent.color, const Color(0xFF2E9E5B));
    expect(profiles.serverWrites.last, const Color(0xFF2E9E5B));

    // Tap Pick from camera option -> opens CameraColorPickerScreen
    await tester.tap(find.byKey(const Key('pickFromCamera')));
    await tester.pumpAndSettle();

    expect(find.text('CAMERA PICKER SCREEN'), findsOneWidget);
  });

  testWidgets('custom color is rendered as a Custom swatch and selected',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(
      initial: AymaColors.accent,
      profileService: profiles,
    );

    const customColor = Color(0xFF1188EE);
    await accent.set(customColor);
    await accent.saveCustomColor(customColor);

    await tester.pumpWidget(host(accent: accent));
    await tester.pumpAndSettle();

    // Custom swatch is rendered
    expect(find.byKey(const Key('accentPreset_custom')), findsOneWidget);
    expect(accent.color, customColor);

    // Switch to another preset
    await tester.tap(find.byKey(const Key('accentPreset_cherry_fuchsia')));
    await tester.pumpAndSettle();
    expect(accent.color, AymaColors.accent);

    // Switch back to custom swatch
    await tester.tap(find.byKey(const Key('accentPreset_custom')));
    await tester.pumpAndSettle();
    expect(accent.color, customColor);
  });
}
